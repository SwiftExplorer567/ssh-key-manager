package migrate

import (
	"bufio"
	"crypto/sha256"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/model"
)

type Result struct {
	Fleet    *model.Fleet
	Warnings []string
}

func stableID(prefix string, values ...string) string {
	digest := sha256.Sum256([]byte(strings.Join(values, "\x00")))
	return fmt.Sprintf("%s_%x", prefix, digest[:8])
}

func FromV1(dir, name string) (*Result, error) {
	if dir == "" {
		h, err := os.UserHomeDir()
		if err != nil {
			return nil, err
		}
		dir = filepath.Join(h, ".config", "ssh-key-manager")
	}
	if name == "" {
		name = "Migrated Fleet"
	}
	f := &model.Fleet{
		Schema:      2,
		FleetID:     stableID("fleet", name),
		Name:        name,
		Subjects:    []model.Subject{},
		Credentials: []model.Credential{},
		Nodes:       []model.Node{},
		Policies:    []model.Policy{},
		Groups:      []model.Group{},
	}
	res := &Result{Fleet: f, Warnings: []string{}}
	principalByAlias := map[string]string{}
	nodeByToken := map[string]int{}

	if err := parse(filepath.Join(dir, "servers.conf"), func(parts []string) error {
		if len(parts) < 4 {
			return nil
		}
		port, _ := strconv.Atoi(parts[3])
		if port == 0 {
			port = 22
		}
		alias, user, host := parts[0], parts[1], parts[2]
		nid := stableID("node", alias, user, host, strconv.Itoa(port))
		pid := stableID("principal", alias, user)
		rid := stableID("route", alias, user, host, strconv.Itoa(port))
		n := model.Node{ID: nid, Name: alias, Principals: []model.Principal{{ID: pid, Username: user, PolicyMode: model.PolicyAdditive, Routes: []model.Route{{ID: rid, Type: "direct", Host: host, Port: port, Priority: 10}}}}}
		f.Nodes = append(f.Nodes, n)
		principalByAlias[alias] = pid
		nodeByToken[knownHostsToken(host, port)] = len(f.Nodes) - 1
		return nil
	}); err != nil && !os.IsNotExist(err) {
		return nil, err
	}

	fpToSubject := map[string]string{}
	if err := parse(filepath.Join(dir, "identities.conf"), func(parts []string) error {
		if len(parts) < 4 {
			return nil
		}
		name, fingerprint := parts[0], parts[1]
		sid := stableID("subject", name, fingerprint)
		cid := stableID("cred", fingerprint)
		f.Subjects = append(f.Subjects, model.Subject{ID: sid, Name: name, Type: parts[2], Status: parts[3]})
		status := model.CredentialActive
		if parts[3] == "retired" {
			status = model.CredentialRetired
		}
		f.Credentials = append(f.Credentials, model.Credential{ID: cid, SubjectID: sid, Fingerprint: fingerprint, Status: status})
		fpToSubject[fingerprint] = sid
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

	if err := migrateKnownHosts(filepath.Join(dir, "known_hosts"), f, nodeByToken, &res.Warnings); err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	return res, nil
}

func knownHostsToken(host string, port int) string {
	if port == 22 {
		return host
	}
	return fmt.Sprintf("[%s]:%d", host, port)
}

func migrateKnownHosts(path string, f *model.Fleet, nodeByToken map[string]int, warnings *[]string) error {
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
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		idx, ok := nodeByToken[fields[0]]
		if !ok {
			continue
		}
		fp, fpErr := hostKeyFingerprint(fields[1], fields[2])
		if fpErr != nil {
			*warnings = append(*warnings, fmt.Sprintf("preserved host key for %s but could not derive fingerprint: %v", f.Nodes[idx].Name, fpErr))
		}
		f.Nodes[idx].HostTrust.Method = "v1-pinned"
		f.Nodes[idx].HostTrust.Keys = append(f.Nodes[idx].HostTrust.Keys, model.HostKey{
			Algorithm:   fields[1],
			PublicKey:   fields[2],
			Fingerprint: fp,
		})
	}
	return s.Err()
}

func hostKeyFingerprint(algorithm, publicKey string) (string, error) {
	cmd := exec.Command("ssh-keygen", "-lf", "/dev/stdin")
	cmd.Stdin = strings.NewReader(algorithm + " " + publicKey + "\n")
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}
	fields := strings.Fields(string(out))
	if len(fields) < 2 || !strings.HasPrefix(fields[1], "SHA256:") {
		return "", fmt.Errorf("unexpected ssh-keygen output")
	}
	return fields[1], nil
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
