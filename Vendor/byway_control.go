package libbox

import (
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/daemon"
	M "github.com/sagernet/sing/common/metadata"
)

type BywayProbeResult struct {
	LatencyMS int32
	ExitIP    string
}

type BywayTrafficTotals struct {
	UploadBytes   int64
	DownloadBytes int64
}

func (s *CommandServer) BywayTraffic() (*BywayTrafficTotals, error) {
	instance := s.Instance()
	if instance == nil || instance.TrafficManager() == nil {
		return nil, errors.New("traffic statistics unavailable")
	}
	upload, download := instance.TrafficManager().Total()
	return &BywayTrafficTotals{UploadBytes: upload, DownloadBytes: download}, nil
}

func (s *CommandServer) BywaySelected() (string, error) {
	instance := s.Instance()
	if instance == nil || instance.Box() == nil {
		return "", errors.New("tunnel unavailable")
	}
	outbound, _ := instance.Box().Outbound().Outbound("byway")
	group, ok := outbound.(adapter.OutboundGroup)
	if !ok {
		return "", errors.New("selector unavailable")
	}
	selected := group.Selected("tcp")
	if selected == nil {
		return "", errors.New("no selected outbound")
	}
	return selected.Tag(), nil
}

func (s *CommandServer) BywaySelect(tag string) error {
	_, err := s.StartedService.SelectOutbound(s.ctx, &daemon.SelectOutboundRequest{
		GroupTag: "byway", OutboundTag: tag,
	})
	return err
}

func (s *CommandServer) bywayHTTPClient(tag string) (*http.Client, error) {
	instance := s.Instance()
	if instance == nil || instance.Box() == nil {
		return nil, errors.New("tunnel unavailable")
	}
	outbound, ok := instance.Box().Outbound().Outbound(tag)
	if !ok {
		return nil, errors.New("outbound unavailable")
	}
	return bywayHTTPClient(outbound), nil
}

func bywayHTTPClient(outbound adapter.Outbound) *http.Client {
	transport := &http.Transport{
		DisableCompression: true,
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			return outbound.DialContext(ctx, network, M.ParseSocksaddr(addr))
		},
	}
	return &http.Client{
		Transport: transport,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

func (s *CommandServer) BywayProbe(tag string) (*BywayProbeResult, error) {
	client, err := s.bywayHTTPClient(tag)
	if err != nil {
		return nil, err
	}
	defer client.CloseIdleConnections()
	ctx, cancel := context.WithTimeout(s.ctx, 8*time.Second)
	defer cancel()
	return bywayProbe(ctx, client)
}

// BywayProbeOutbound runs a single outbound without a TUN device or a listener.
func BywayProbeOutbound(outboundConfig string) (*BywayProbeResult, error) {
	ctx, cancel := context.WithTimeout(baseContext(nil), 8*time.Second)
	defer cancel()
	options, err := parseConfig(ctx, `{"log":{"disabled":true},"outbounds":[`+outboundConfig+`]}`)
	if err != nil {
		return nil, err
	}
	instance, err := box.New(box.Options{Context: ctx, Options: options})
	if err != nil {
		return nil, err
	}
	defer instance.Close()
	if err := instance.Start(); err != nil {
		return nil, err
	}
	client := bywayHTTPClient(instance.Outbound().Default())
	defer client.CloseIdleConnections()
	return bywayProbe(ctx, client)
}

func bywayProbe(ctx context.Context, client *http.Client) (*BywayProbeResult, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://www.cloudflare.com/cdn-cgi/trace", nil)
	if err != nil {
		return nil, err
	}
	startedAt := time.Now()
	response, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, errors.New("probe returned an unexpected status")
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 4096))
	if err != nil {
		return nil, err
	}
	for _, line := range strings.Split(string(body), "\n") {
		value, ok := strings.CutPrefix(strings.TrimSpace(line), "ip=")
		if ok && net.ParseIP(value) != nil {
			return &BywayProbeResult{LatencyMS: int32(time.Since(startedAt).Milliseconds()), ExitIP: value}, nil
		}
	}
	return nil, errors.New("probe did not report an IP address")
}

type BywayHealthHandler interface {
	OnHealthResult(healthy bool)
}

func (s *CommandServer) BywayStartHealthCheck(tag string, handler BywayHealthHandler) (*BywayNetworkTask, error) {
	if handler == nil {
		return nil, errors.New("missing health check handler")
	}
	client, err := s.bywayHTTPClient(tag)
	if err != nil {
		return nil, err
	}
	return startBywayNetworkTask(s.ctx, 8*time.Second, func(ctx context.Context) {
		defer client.CloseIdleConnections()
		_, err := bywayProbe(ctx, client)
		handler.OnHealthResult(err == nil)
	}), nil
}

type BywaySpeedResult struct {
	DownloadBitsPerSecond int64
	UploadBitsPerSecond   int64
}

type BywaySpeedTestHandler interface {
	OnComplete(result *BywaySpeedResult, message string)
}

type BywayNetworkTask struct {
	cancel context.CancelFunc
	done   chan struct{}
}

func (t *BywayNetworkTask) Cancel() {
	t.cancel()
	<-t.done
}

func startBywayNetworkTask(parent context.Context, timeout time.Duration, run func(context.Context)) *BywayNetworkTask {
	ctx, cancel := context.WithTimeout(parent, timeout)
	task := &BywayNetworkTask{cancel: cancel, done: make(chan struct{})}
	go func() {
		defer close(task.done)
		defer cancel()
		run(ctx)
	}()
	return task
}

func (s *CommandServer) BywayStartSpeedTest(tag string, handler BywaySpeedTestHandler) (*BywayNetworkTask, error) {
	if handler == nil {
		return nil, errors.New("missing speed test handler")
	}
	client, err := s.bywayHTTPClient(tag)
	if err != nil {
		return nil, err
	}
	return startBywayNetworkTask(s.ctx, 25*time.Second, func(ctx context.Context) {
		defer client.CloseIdleConnections()
		result, err := bywayMeasureSpeed(ctx, client, "https://speed.cloudflare.com")
		switch {
		case errors.Is(ctx.Err(), context.Canceled):
			handler.OnComplete(nil, "测速已取消")
		case errors.Is(ctx.Err(), context.DeadlineExceeded):
			handler.OnComplete(nil, "带宽测速超时")
		case err != nil:
			handler.OnComplete(nil, "无法通过该节点完成带宽测速")
		default:
			handler.OnComplete(result, "")
		}
	}), nil
}

func bywayMeasureSpeed(ctx context.Context, client *http.Client, endpoint string) (*BywaySpeedResult, error) {
	const downloadBytes = 4_000_000
	const uploadBytes = 1_000_000
	request, err := http.NewRequestWithContext(ctx, http.MethodGet,
		fmt.Sprintf("%s/__down?bytes=%d", endpoint, downloadBytes), nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Cache-Control", "no-cache")
	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}
	startedAt := time.Now()
	if response.StatusCode != http.StatusOK {
		response.Body.Close()
		return nil, errors.New("download returned an unexpected status")
	}
	count, err := io.Copy(io.Discard, io.LimitReader(response.Body, downloadBytes+1))
	downloadDuration := time.Since(startedAt)
	response.Body.Close()
	if err != nil || count != downloadBytes {
		return nil, errors.New("download sample was incomplete")
	}

	body := make([]byte, uploadBytes)
	if _, err := rand.Read(body); err != nil {
		return nil, err
	}
	request, err = http.NewRequestWithContext(ctx, http.MethodPost, endpoint+"/__up", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	request.Header.Set("Content-Type", "application/octet-stream")
	startedAt = time.Now()
	response, err = client.Do(request)
	if err != nil {
		return nil, err
	}
	uploadDuration := time.Since(startedAt)
	response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, errors.New("upload returned an unexpected status")
	}
	return &BywaySpeedResult{
		DownloadBitsPerSecond: int64(downloadBytes * 8 / downloadDuration.Seconds()),
		UploadBitsPerSecond:   int64(uploadBytes * 8 / uploadDuration.Seconds()),
	}, nil
}
