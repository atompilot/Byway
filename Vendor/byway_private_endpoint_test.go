//go:build with_tailscale

package tailscale

import (
	"errors"
	"fmt"
	"net"
	"testing"

	"github.com/sagernet/tailscale/tailcfg"
)

func TestBywayRelayPolicy(t *testing.T) {
	policy := newBywayPrivatePolicy([]string{"Derp.Example.net."}, false)
	if policy.allowed() {
		t.Fatal("private traffic admitted before a DERP map is available")
	}
	approved := &tailcfg.DERPMap{Regions: map[int]*tailcfg.DERPRegion{
		914: {RegionID: 914, Nodes: []*tailcfg.DERPNode{{HostName: "derp.example.net"}}},
	}}
	if policy.filter(approved) != approved || !policy.allowed() {
		t.Fatal("approved DERP map was rejected")
	}
	left, right := net.Pipe()
	defer left.Close()
	defer right.Close()
	conn := policy.guardConnection(left)

	mixed := &tailcfg.DERPMap{Regions: map[int]*tailcfg.DERPRegion{
		914: approved.Regions[914],
		1:   {RegionID: 1, Nodes: []*tailcfg.DERPNode{{HostName: "public.example.net"}}},
	}}
	if filtered := policy.filter(mixed); filtered != nil || policy.allowed() {
		t.Fatal("unapproved DERP map was made available")
	}
	if result := policy.audit.Load(); result == nil || result.Verified || len(result.Hosts) != 2 {
		t.Fatal("the rejected map must remain available for diagnosis")
	}
	if _, err := conn.Write([]byte("blocked")); !errors.Is(err, errBywayRelayPolicy) {
		t.Fatalf("existing connection bypassed updated policy: %v", err)
	}
	if policy.filter(approved) != approved || !policy.allowed() {
		t.Fatal("correcting the DERP map did not restore private traffic")
	}
	if policy.filter(nil) != nil || policy.allowed() {
		t.Fatal("clearing the DERP map did not close the application path")
	}
}

func TestBywayRelayPolicyChecksTLSIdentity(t *testing.T) {
	policy := newBywayPrivatePolicy([]string{"derp.example.net"}, false)
	mapWithOverride := &tailcfg.DERPMap{Regions: map[int]*tailcfg.DERPRegion{
		914: {RegionID: 914, Nodes: []*tailcfg.DERPNode{
			{HostName: "derp.example.net", CertName: "unapproved.example.net"},
		}},
	}}
	if filtered := policy.filter(mapWithOverride); filtered != nil || policy.allowed() {
		t.Fatal("a relay with a different TLS identity was admitted")
	}
}

func TestBywayRelayPolicyFollowsControlMap(t *testing.T) {
	policy := newBywayPrivatePolicy(nil, true)
	filter := policy.filterFunc()
	if policy.allowed() {
		t.Fatal("private traffic admitted before a DERP map is available")
	}
	dm := &tailcfg.DERPMap{Regions: make(map[int]*tailcfg.DERPRegion)}
	for i := 1; i <= 24; i++ {
		dm.Regions[i] = &tailcfg.DERPRegion{RegionID: i, Nodes: []*tailcfg.DERPNode{{
			HostName: fmt.Sprintf("derp%d.example.net", i),
			CertName: "relay.example.net",
		}}}
	}
	if filter(dm) != dm || !policy.allowed() {
		t.Fatal("following control should deliver the entire, unmodified map")
	}
	if audit := policy.audit.Load(); audit == nil || !audit.Verified || len(audit.Hosts) != 24 {
		t.Fatalf("the entire map should be visible in the audit: %+v", audit)
	}
	strict := newBywayPrivatePolicy([]string{"derp1.example.net"}, false)
	if strict.filter(dm) != nil || strict.allowed() {
		t.Fatal("an explicit allowlist must still reject the expanded map")
	}
	updated := &tailcfg.DERPMap{Regions: map[int]*tailcfg.DERPRegion{
		25: {RegionID: 25, Nodes: []*tailcfg.DERPNode{{HostName: "new.example.net"}}},
	}}
	if filter(updated) != updated || !policy.allowed() || policy.audit.Load().Hosts[0] != "new.example.net" {
		t.Fatal("the policy did not follow a changed control map")
	}
	if filter(nil) != nil || policy.allowed() || policy.audit.Load() != nil {
		t.Fatal("clearing the map must clear the audit and close the application path")
	}
}

func TestBywayRelayPolicyWithoutOptions(t *testing.T) {
	policy := newBywayPrivatePolicy(nil, false)
	if policy != nil || !policy.allowed() || policy.filterFunc() != nil {
		t.Fatal("an unrelated Tailscale endpoint should retain upstream behavior")
	}
	if policy := newBywayPrivatePolicy([]string{}, false); policy == nil || policy.allowed() {
		t.Fatal("an explicitly empty strict list must not enable traffic")
	}
}
