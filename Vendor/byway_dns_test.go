package include

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"

	mDNS "github.com/miekg/dns"
)

func TestBywayDNS(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	primary := new(dnsTestServer)
	backup := &dnsTestServer{slowProbe: true}
	transport := &bywayDNS{
		ctx: ctx, exit: "byway", outbounds: dnsTestOutbounds{},
		servers: []adapter.DNSTransport{primary, backup},
		choices: make(map[string]*bywayDNSChoice),
	}
	query := func(domain string, expectedRCode int) {
		t.Helper()
		answer, err := transport.Exchange(ctx, new(mDNS.Msg).SetQuestion(domain, mDNS.TypeA))
		if err != nil || answer == nil || answer.Rcode != expectedRCode {
			t.Fatalf("unexpected DNS result for %s: %v %v", domain, answer, err)
		}
	}
	query("reachable.example.", mDNS.RcodeSuccess)
	query("absent.example.", mDNS.RcodeNameError)
	if backup.queries.Load() != 0 {
		t.Fatal("a successful or negative primary response should not reach the backup")
	}
	primary.failed.Store(true)
	query("first-failure.example.", mDNS.RcodeSuccess)
	query("second-failure.example.", mDNS.RcodeSuccess)
	query("after-promotion.example.", mDNS.RcodeSuccess)
	if primary.queries.Load() != 4 || backup.queries.Load() != 3 {
		t.Fatalf("expected the backup to be promoted after two failures, got %d primary and %d backup queries",
			primary.queries.Load(), backup.queries.Load())
	}
}

type dnsTestOutbounds struct{ adapter.OutboundManager }

func (dnsTestOutbounds) Outbound(string) (adapter.Outbound, bool) { return nil, false }

type dnsTestServer struct {
	adapter.DNSTransport
	failed    atomic.Bool
	queries   atomic.Int32
	slowProbe bool
}

func (s *dnsTestServer) Exchange(ctx context.Context, query *mDNS.Msg) (*mDNS.Msg, error) {
	answer := new(mDNS.Msg).SetReply(query)
	switch query.Question[0].Name {
	case "example.com.":
		if s.slowProbe {
			<-ctx.Done()
			return nil, ctx.Err()
		}
		address, _ := mDNS.NewRR("example.com. 30 IN A 192.0.2.42")
		answer.Answer = []mDNS.RR{address}
	case "absent.example.":
		s.queries.Add(1)
		answer.Rcode = mDNS.RcodeNameError
	default:
		s.queries.Add(1)
		if s.failed.Load() {
			return nil, errors.New("upstream unavailable")
		}
	}
	return answer, nil
}
