package migrate

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/model"
	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/store"
)

type Result struct {
	Fleet    *model.Fleet
	Warnings []string
}

func FromV1(dir, name string) (*Result, error) {
	if dir == "" {
		h, err := os.UserHomeDir()
		if err != nil {
			return nil, err
		}
		dir = filepath.Join(h, ".config", "ssh-key-manager")
	}
	f := &model.Fleet{Schema: 2, FleetID: store.NewID("fleet"), Name: name}
	if f.Name == "" {
		f.Name = "Migrated Fleet"
	}
	res := &Result{Fleet: f}
	principalByAlias := map[string]string{}
	if err := parse(filepath.Join(dir, "servers.conf"), func(parts []string) error {
		if len(parts) < 4 {
			return nil
		}
		port, _ := strconv.Atoi(parts[3])
		if port == 0 {
			port = 22
		}
		nid := store.NewID("node")
		pid := store.NewID("principal")
		rid := store.NewID("route")
		n := model.Node{ID: nid, Name: parts[0], Principals: []model.Principal{{ID: pid, Username: parts[1], PolicyMode: model.PolicyAdditive, Routes: []model.Route{{ID: rid, Type: "direct", Host: parts[2], Port: port, Priority: 10}}}}}
		f.Nodes = append(f.Nodes, n)
		principalByAlias[parts[0]] = pid
		return nil
	}); err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	fpToSubject := map[string]string{}
	if err := parse(filepath.Join(dir, "identities.conf"), func(parts []string) error {
		if len(parts) < 4 {
			return nil
		}
		sid := store.NewID("subject")
		cid := store.NewID("cred")
		f.Subjects = append(f.Subjects, model.Subject{ID: sid, Name: parts[0], Type: parts[2], Status: parts[3]})
		status := model.CredentialActive
		if parts[3] == "retired" {
			status = model.CredentialRetired
		}
		f.Credentials = append(f.Credentials, model.Credential{ID: cid, SubjectID: sid, Fingerprint: parts[1], Status: status})
		fpToSubject[parts[1]] = sid
		return nil
	}); err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	if err := parse(filepath.Join(dir, "policy.conf"), func(parts []string) error {
		if len(parts) < 2 {
			return nil
		}
		sid, sok := fpToSubject[parts[0]]
		pid, pok := principalByAlias[parts[1]]
		if !sok || !pok {
			res.Warnings = append(res.Warnings, fmt.Sprintf("skipped stale v1 policy %s -> %s", parts[0], parts[1]))
			return nil
		}
		f.Policies = append(f.Policies, model.Policy{SubjectID: sid, PrincipalID: pid})
		return nil
	}); err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	return res, nil
}

func parse(path string, fn func([]string) error) error {
	fh, err := os.Open(path)
	if err != nil {
		return err
	}
	defer fh.Close()
	s := bufio.NewScanner(fh)
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if err := fn(strings.Split(line, "|")); err != nil {
			return err
		}
	}
	return s.Err()
}
