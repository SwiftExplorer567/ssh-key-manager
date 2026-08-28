package main

import (
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/model"
	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/store"
)

func parsePositiveInt(value, label string, fallback int) (int, error) {
	if strings.TrimSpace(value) == "" {
		return fallback, nil
	}
	v, err := strconv.Atoi(value)
	if err != nil || v < 1 {
		return 0, fmt.Errorf("%s must be a positive integer", label)
	}
	return v, nil
}

func listRoutes(f *model.Fleet, nodeName, user string) ([]model.Route, error) {
	ni, pi, err := findPrincipalIndex(f, nodeName, user)
	if err != nil {
		return nil, err
	}
	routes := append([]model.Route(nil), f.Nodes[ni].Principals[pi].Routes...)
	sort.SliceStable(routes, func(i, j int) bool {
		if routes[i].Priority == routes[j].Priority {
			return routes[i].ID < routes[j].ID
		}
		return routes[i].Priority < routes[j].Priority
	})
	return routes, nil
}

func addRoute(f *model.Fleet, nodeName, user, routeType, destination string, port, priority int, proxyJump string) (*model.Route, error) {
	ni, pi, err := findPrincipalIndex(f, nodeName, user)
	if err != nil {
		return nil, err
	}
	routeType = strings.TrimSpace(routeType)
	destination = strings.TrimSpace(destination)
	proxyJump = strings.TrimSpace(proxyJump)
	if destination == "" {
		return nil, errors.New("route destination required")
	}
	if priority < 1 {
		return nil, errors.New("route priority must be positive")
	}

	r := model.Route{ID: store.NewID("route"), Type: routeType, Priority: priority, ProxyJump: proxyJump}
	switch routeType {
	case "direct", "tailscale":
		r.Host = destination
		if port == 0 {
			port = 22
		}
		r.Port = port
	case "ssh-config":
		r.SSHConfigAlias = destination
		r.Port = port
	default:
		return nil, fmt.Errorf("unsupported route type %q (want direct, tailscale or ssh-config)", routeType)
	}

	pr := &f.Nodes[ni].Principals[pi]
	for _, existing := range pr.Routes {
		if existing.Type == r.Type && existing.Host == r.Host && existing.SSHConfigAlias == r.SSHConfigAlias && existing.Port == r.Port && existing.ProxyJump == r.ProxyJump {
			return nil, fmt.Errorf("equivalent route already exists: %s", existing.ID)
		}
	}
	pr.Routes = append(pr.Routes, r)
	sort.SliceStable(pr.Routes, func(i, j int) bool {
		if pr.Routes[i].Priority == pr.Routes[j].Priority {
			return pr.Routes[i].ID < pr.Routes[j].ID
		}
		return pr.Routes[i].Priority < pr.Routes[j].Priority
	})
	if err := store.Save(f); err != nil {
		return nil, err
	}
	for i := range pr.Routes {
		if pr.Routes[i].ID == r.ID {
			return &pr.Routes[i], nil
		}
	}
	return nil, errors.New("route save invariant failed")
}

func removeRoute(f *model.Fleet, nodeName, user, routeID string) error {
	ni, pi, err := findPrincipalIndex(f, nodeName, user)
	if err != nil {
		return err
	}
	pr := &f.Nodes[ni].Principals[pi]
	if len(pr.Routes) <= 1 {
		return errors.New("refusing to remove the last route from a principal")
	}
	out := pr.Routes[:0]
	removed := false
	for _, r := range pr.Routes {
		if r.ID == routeID {
			removed = true
			continue
		}
		out = append(out, r)
	}
	if !removed {
		return fmt.Errorf("route not found: %s", routeID)
	}
	pr.Routes = out
	return store.Save(f)
}
