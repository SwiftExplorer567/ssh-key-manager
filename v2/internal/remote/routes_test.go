package remote

import (
	"testing"

	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/model"
)

func TestNormalizeTailscaleRoute(t *testing.T) {
	r, err := normalizeRoute(model.Route{ID: "r", Type: "tailscale", Host: "100.64.0.10", Priority: 10})
	if err != nil { t.Fatal(err) }
	if r.Host != "100.64.0.10" || r.Port != 22 { t.Fatalf("route=%#v", r) }
}

func TestResolveSSHConfigRouteUsesEffectiveHost(t *testing.T) {
	r, err := normalizeRoute(model.Route{ID: "r", Type: "ssh-config", SSHConfigAlias: "example.com", Priority: 10})
	if err != nil { t.Fatal(err) }
	if r.Host == "" || r.Port == 0 || r.SSHConfigAlias != "example.com" { t.Fatalf("route=%#v", r) }
}

func TestResolveTargetSkipsUnsupportedHigherPriorityRoute(t *testing.T) {
	f := &model.Fleet{Nodes: []model.Node{{
		Name: "server",
		Principals: []model.Principal{{
			ID: "p", Username: "root",
			Routes: []model.Route{
				{ID: "bad", Type: "future", Host: "bad", Priority: 1},
				{ID: "ts", Type: "tailscale", Host: "100.64.0.10", Priority: 2},
			},
		}},
	}}}
	target, err := resolveTarget(f, "server", "")
	if err != nil { t.Fatal(err) }
	if target.Route.ID != "ts" || target.Route.Port != 22 { t.Fatalf("target=%#v", target) }
}
