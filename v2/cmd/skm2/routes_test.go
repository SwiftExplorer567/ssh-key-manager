package main

import (
	"path/filepath"
	"testing"

	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/model"
)

func routeTestFleet() *model.Fleet {
	return &model.Fleet{
		Schema: 2,
		FleetID: "fleet",
		Name: "test",
		Nodes: []model.Node{{
			ID: "n",
			Name: "server",
			Principals: []model.Principal{{
				ID: "p",
				Username: "root",
				PolicyMode: model.PolicyAdditive,
				Routes: []model.Route{{ID: "r1", Type: "direct", Host: "10.0.0.1", Port: 22, Priority: 10}},
			}},
		}},
	}
}

func TestAddAndOrderRoutes(t *testing.T) {
	t.Setenv("SKM2_CONFIG_DIR", filepath.Join(t.TempDir(), "config"))
	f := routeTestFleet()
	r, err := addRoute(f, "server", "", "tailscale", "100.64.0.10", 22, 5, "")
	if err != nil { t.Fatal(err) }
	if r.Type != "tailscale" || r.Host != "100.64.0.10" { t.Fatalf("route=%#v", r) }
	routes, err := listRoutes(f, "server", "")
	if err != nil { t.Fatal(err) }
	if len(routes) != 2 || routes[0].ID != r.ID { t.Fatalf("routes=%#v", routes) }
}

func TestRemoveLastRouteRefused(t *testing.T) {
	t.Setenv("SKM2_CONFIG_DIR", filepath.Join(t.TempDir(), "config"))
	f := routeTestFleet()
	if err := removeRoute(f, "server", "", "r1"); err == nil {
		t.Fatal("expected last-route refusal")
	}
}

func TestSSHConfigRouteStoresAlias(t *testing.T) {
	t.Setenv("SKM2_CONFIG_DIR", filepath.Join(t.TempDir(), "config"))
	f := routeTestFleet()
	r, err := addRoute(f, "server", "", "ssh-config", "my-server", 0, 20, "")
	if err != nil { t.Fatal(err) }
	if r.SSHConfigAlias != "my-server" || r.Host != "" { t.Fatalf("route=%#v", r) }
}
