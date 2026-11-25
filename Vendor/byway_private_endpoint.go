//go:build with_tailscale

package tailscale

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/netip"
	"slices"
	"strings"
	"sync/atomic"
	"time"

	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/tailscale/ipn"
	"github.com/sagernet/tailscale/tailcfg"
)

var errBywayRelayPolicy = errors.New("private network relay policy is not ready or does not match")

type bywayRelayAudit struct {
	Hosts    []string `json:"hosts"`
	Verified bool     `json:"verified"`
}

type bywayPrivatePolicy struct {
	expected      []string
	followControl bool
	audit         atomic.Pointer[bywayRelayAudit]
}

func bywayHost(host string) string {
	return strings.ToLower(strings.TrimSuffix(strings.TrimSpace(host), "."))
}

func newBywayPrivatePolicy(hosts []string, followControl bool) *bywayPrivatePolicy {
	if hosts == nil && !followControl {
		return nil
	}
	expected := make([]string, 0, len(hosts))
	for _, host := range hosts {
		expected = append(expected, bywayHost(host))
	}
	slices.Sort(expected)
	return &bywayPrivatePolicy{expected: slices.Compact(expected), followControl: followControl}
}

func (p *bywayPrivatePolicy) allowed() bool {
	if p == nil {
		return true
	}
	audit := p.audit.Load()
	return audit != nil && audit.Verified
}

func (p *bywayPrivatePolicy) filterFunc() func(*tailcfg.DERPMap) *tailcfg.DERPMap {
	if p == nil {
		return nil
	}
	return p.filter
}

func (p *bywayPrivatePolicy) filter(dm *tailcfg.DERPMap) *tailcfg.DERPMap {
	if dm == nil {
		p.audit.Store(nil)
		return nil
	}
	hosts := []string{}
	valid := true
	hasRelay := false
	for _, region := range dm.Regions {
		if region == nil {
			valid = false
			continue
		}
		for _, node := range region.Nodes {
			if node == nil {
				valid = false
				continue
			}
			host := bywayHost(node.HostName)
			hosts = append(hosts, host)
			certName := bywayHost(node.CertName)
			valid = valid && host != "" && !node.InsecureForTests && (certName == "" || certName == host)
			hasRelay = hasRelay || !node.STUNOnly
		}
	}
	slices.Sort(hosts)
	hosts = slices.Compact(hosts)
	verified := p.followControl || (valid && hasRelay && slices.Equal(hosts, p.expected))
	p.audit.Store(&bywayRelayAudit{Hosts: hosts, Verified: verified})
	if !verified {
		return nil
	}
	return dm
}

type bywayPrivatePeer struct {
	ID        string   `json:"id"`
	Name      string   `json:"name"`
	DNSName   string   `json:"dnsName"`
	OS        string   `json:"os"`
	Addresses []string `json:"addresses"`
	Online    bool     `json:"online"`
}

type bywayPrivateSnapshot struct {
	State     string             `json:"state"`
	Network   string             `json:"network,omitempty"`
	DNS       string             `json:"dnsSuffix,omitempty"`
	Addresses []string           `json:"addresses"`
	Peers     []bywayPrivatePeer `json:"peers"`
	Relays    *bywayRelayAudit   `json:"relays,omitempty"`
	AuthURL   string             `json:"authURL,omitempty"`
}

func bywayAddresses(addresses []netip.Addr) []string {
	result := make([]string, 0, len(addresses))
	for _, address := range addresses {
		result = append(result, address.String())
	}
	return result
}

func (t *Endpoint) BywayPrivateStatus(ctx context.Context) ([]byte, error) {
	if t.byway == nil || !t.started.Load() {
		return nil, errors.New("private network is not running")
	}
	client, err := t.server.LocalClient()
	if err != nil {
		return nil, err
	}
	status, err := client.Status(ctx)
	if err != nil {
		return nil, err
	}
	snapshot := bywayPrivateSnapshot{
		State: status.BackendState, AuthURL: status.AuthURL, Relays: t.byway.audit.Load(),
		Addresses: bywayAddresses(status.TailscaleIPs), Peers: []bywayPrivatePeer{},
	}
	if status.CurrentTailnet != nil {
		snapshot.Network = status.CurrentTailnet.Name
		snapshot.DNS = strings.TrimSuffix(status.CurrentTailnet.MagicDNSSuffix, ".")
	}
	if snapshot.Relays != nil && !snapshot.Relays.Verified &&
		status.BackendState != ipn.NeedsLogin.String() && status.BackendState != ipn.NeedsMachineAuth.String() {
		snapshot.State = "RelayMismatch"
	}
	for _, peer := range status.Peer {
		snapshot.Peers = append(snapshot.Peers, bywayPrivatePeer{
			ID: string(peer.ID), Name: peer.HostName, DNSName: strings.TrimSuffix(peer.DNSName, "."),
			OS: peer.OS, Addresses: bywayAddresses(peer.TailscaleIPs), Online: peer.Online,
		})
	}
	slices.SortFunc(snapshot.Peers, func(a, b bywayPrivatePeer) int {
		if order := strings.Compare(strings.ToLower(a.Name), strings.ToLower(b.Name)); order != 0 {
			return order
		}
		return strings.Compare(a.ID, b.ID)
	})
	return json.Marshal(snapshot)
}

func (t *Endpoint) BywayPrivateAction(ctx context.Context, action, value string) ([]byte, error) {
	if t.byway == nil || !t.started.Load() {
		return nil, errors.New("private network is not running")
	}
	client, err := t.server.LocalClient()
	if err != nil {
		return nil, err
	}
	switch action {
	case "join":
		status, err := client.StatusWithoutPeers(ctx)
		if err != nil || status.BackendState != ipn.NeedsLogin.String() {
			return nil, errors.New("start a new private network registration first")
		}
		if value != "" {
			prefs := ipn.NewPrefs()
			prefs.WantRunning = true
			prefs.ControlURL = t.server.ControlURL
			prefs.Hostname = t.server.Hostname
			err = client.Start(ctx, ipn.Options{UpdatePrefs: prefs, AuthKey: value})
			if err != nil {
				return nil, errors.New("private network registration failed")
			}
		}
		if err := client.StartLoginInteractive(ctx); err != nil {
			return nil, errors.New("private network registration failed")
		}
		return []byte(`{}`), nil
	case "probe":
		if !t.byway.allowed() {
			return nil, errBywayRelayPolicy
		}
		address, err := netip.ParseAddr(value)
		if err != nil {
			return nil, errors.New("invalid private network address")
		}
		peer, ok := t.server.ExportLocalBackend().PeerForIP(address)
		if !ok || peer.IsSelf || peer.Route.Bits() != address.BitLen() {
			return nil, errors.New("unknown private network device")
		}
		probeCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		ping, err := client.Ping(probeCtx, address, tailcfg.PingDisco)
		if err != nil || ping == nil || ping.Err != "" {
			return nil, errors.New("private network device did not respond")
		}
		path := "unknown"
		switch {
		case ping.Endpoint != "":
			path = "direct"
		case ping.PeerRelay != "":
			path = "peerRelay"
		case ping.DERPRegionID != 0:
			path = "derp"
		}
		return json.Marshal(map[string]any{
			"path": path, "region": ping.DERPRegionCode, "latencyMs": ping.LatencySeconds * 1000,
			"observedAt": time.Now().UTC(),
		})
	default:
		return nil, errors.New("unknown private network operation")
	}
}

type bywayGuardedConn struct {
	net.Conn
	policy *bywayPrivatePolicy
}

func (p *bywayPrivatePolicy) guardConnection(conn net.Conn) net.Conn {
	if p == nil || conn == nil {
		return conn
	}
	if _, alreadyGuarded := conn.(*bywayGuardedConn); alreadyGuarded {
		return conn
	}
	return &bywayGuardedConn{Conn: conn, policy: p}
}

func (c *bywayGuardedConn) Read(data []byte) (int, error) {
	if !c.policy.allowed() {
		return 0, errBywayRelayPolicy
	}
	count, err := c.Conn.Read(data)
	if !c.policy.allowed() {
		return 0, errBywayRelayPolicy
	}
	return count, err
}

func (c *bywayGuardedConn) Write(data []byte) (int, error) {
	if !c.policy.allowed() {
		return 0, errBywayRelayPolicy
	}
	return c.Conn.Write(data)
}

func (c *bywayGuardedConn) CloseRead() error  { return N.CloseRead(c.Conn) }
func (c *bywayGuardedConn) CloseWrite() error { return N.CloseWrite(c.Conn) }

type bywayGuardedPacket struct {
	net.PacketConn
	policy *bywayPrivatePolicy
}

func (p *bywayPrivatePolicy) guardPacket(conn net.PacketConn) net.PacketConn {
	if p == nil || conn == nil {
		return conn
	}
	return &bywayGuardedPacket{PacketConn: conn, policy: p}
}

func (c *bywayGuardedPacket) ReadFrom(data []byte) (int, net.Addr, error) {
	if !c.policy.allowed() {
		return 0, nil, errBywayRelayPolicy
	}
	count, addr, err := c.PacketConn.ReadFrom(data)
	if !c.policy.allowed() {
		return 0, nil, errBywayRelayPolicy
	}
	return count, addr, err
}

func (c *bywayGuardedPacket) WriteTo(data []byte, addr net.Addr) (int, error) {
	if !c.policy.allowed() {
		return 0, errBywayRelayPolicy
	}
	return c.PacketConn.WriteTo(data, addr)
}
