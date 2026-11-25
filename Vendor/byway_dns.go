package include

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/dns"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/protocol/group"
	"github.com/sagernet/sing/service"

	mDNS "github.com/miekg/dns"
)

const bywayDNSType = "byway-dns"
const bywayDNSTimeout = 1500 * time.Millisecond

type bywayDNSOptions struct {
	Servers []string `json:"servers"`
	Exit    string   `json:"exit"`
}

type bywayDNSChoice struct {
	ready     chan struct{}
	preferred int
	failures  int
}

type bywayDNS struct {
	dns.TransportAdapter
	ctx       context.Context
	cancel    context.CancelFunc
	manager   adapter.DNSTransportManager
	outbounds adapter.OutboundManager
	exit      string
	servers   []adapter.DNSTransport
	mu        sync.Mutex
	choices   map[string]*bywayDNSChoice
}

func registerBywayDNS(registry *dns.TransportRegistry) {
	dns.RegisterTransport(registry, bywayDNSType, newBywayDNS)
}

func newBywayDNS(ctx context.Context, _ log.ContextLogger, tag string, options bywayDNSOptions) (adapter.DNSTransport, error) {
	if len(options.Servers) < 1 || len(options.Servers) > 8 || options.Exit == "" {
		return nil, errors.New("automatic DNS requires an exit and 1 to 8 servers")
	}
	ctx, cancel := context.WithCancel(ctx)
	return &bywayDNS{
		TransportAdapter: dns.NewTransportAdapter(bywayDNSType, tag, options.Servers),
		ctx:              ctx, cancel: cancel, exit: options.Exit,
		manager:   service.FromContext[adapter.DNSTransportManager](ctx),
		outbounds: service.FromContext[adapter.OutboundManager](ctx),
		choices:   make(map[string]*bywayDNSChoice),
	}, nil
}

func (t *bywayDNS) Start(stage adapter.StartStage, _ *adapter.Scope) error {
	switch stage {
	case adapter.StartStateStart:
		for _, tag := range t.Dependencies() {
			server, ok := t.manager.Transport(tag)
			if !ok || server.Type() != "https" {
				return errors.New("automatic DNS requires HTTPS servers")
			}
			t.servers = append(t.servers, server)
		}
	case adapter.StartStateStarted:
		t.choice(t.exitKey())
	}
	return nil
}

func (t *bywayDNS) Close() error {
	t.cancel()
	return nil
}

func (t *bywayDNS) Reset() {
	t.mu.Lock()
	clear(t.choices)
	t.mu.Unlock()
}

func (t *bywayDNS) exitKey() string {
	if outbound, ok := t.outbounds.Outbound(t.exit); ok {
		if tag := group.RealTag(outbound, "tcp"); tag != "" {
			return tag
		}
	}
	return t.exit
}

func (t *bywayDNS) choice(exit string) *bywayDNSChoice {
	t.mu.Lock()
	defer t.mu.Unlock()
	if choice := t.choices[exit]; choice != nil {
		return choice
	}
	choice := &bywayDNSChoice{ready: make(chan struct{})}
	t.choices[exit] = choice
	if len(t.servers) == 1 {
		close(choice.ready)
	} else {
		go t.probe(exit, choice)
	}
	return choice
}

func (t *bywayDNS) probe(exit string, choice *bywayDNSChoice) {
	defer close(choice.ready)
	ctx, cancel := context.WithTimeout(t.ctx, bywayDNSTimeout)
	defer cancel()
	results := make(chan int, len(t.servers))
	for index, server := range t.servers {
		go func() {
			query := new(mDNS.Msg).SetQuestion("example.com.", mDNS.TypeA)
			answer, err := server.Exchange(ctx, query)
			if err == nil && answer != nil && answer.Rcode == mDNS.RcodeSuccess && len(answer.Answer) != 0 {
				results <- index
			} else {
				results <- -1
			}
		}()
	}
	for range t.servers {
		select {
		case <-ctx.Done():
			return
		case index := <-results:
			if index >= 0 && t.exitKey() == exit {
				t.mu.Lock()
				choice.preferred = index
				t.mu.Unlock()
				return
			}
		}
	}
}

func (t *bywayDNS) Exchange(ctx context.Context, query *mDNS.Msg) (*mDNS.Msg, error) {
	exit := t.exitKey()
	choice := t.choice(exit)
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-choice.ready:
	}
	t.mu.Lock()
	preferred := choice.preferred
	t.mu.Unlock()
	for offset := range t.servers {
		index := (preferred + offset) % len(t.servers)
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		attempt, cancel := context.WithTimeout(ctx, bywayDNSTimeout)
		answer, err := t.servers[index].Exchange(attempt, query.Copy())
		cancel()
		if err == nil && answer != nil && !answer.Truncated &&
			(answer.Rcode == mDNS.RcodeSuccess || answer.Rcode == mDNS.RcodeNameError) {
			if t.exitKey() == exit {
				t.recordSuccess(choice, preferred, index)
			}
			return answer, nil
		}
	}
	return nil, errors.New("all configured DNS servers failed")
}

func (t *bywayDNS) recordSuccess(choice *bywayDNSChoice, preferred, answered int) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if choice.preferred != preferred {
		return
	}
	if answered == preferred {
		choice.failures = 0
	} else {
		choice.failures++
		if choice.failures >= 2 {
			choice.preferred = answered
			choice.failures = 0
		}
	}
}

func (t *bywayDNS) ExchangeAsync(ctx context.Context, query *mDNS.Msg, callback func(*mDNS.Msg, error)) {
	go func() { callback(t.Exchange(ctx, query)) }()
}
