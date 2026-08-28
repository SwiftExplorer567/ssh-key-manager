package remote

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/model"
	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/store"
)

type HostTrustScan struct {
	Node     string          `json:"node"`
	Username string          `json:"username"`
	Route    model.Route     `json:"route"`
	Keys     []model.HostKey `json:"keys"`
}

type HostTrustVerification struct {
	Node        string          `json:"node"`
	Username    string          `json:"username"`
	OK          bool            `json:"ok"`
	Matched     []string        `json:"matched_fingerprints"`
	Presented   []model.HostKey `json:"presented_keys"`
	TrustedKeys []model.HostKey `json:"trusted_keys"`
}

func hostKeyFromPublicLine(line string) (model.HostKey, error) {
	fields := strings.Fields(strings.TrimSpace(line))
	if len(fields) < 2 {
		return model.HostKey{}, errors.New("invalid SSH host public key")
	}
	algorithm := fields[0]
	if !strings.HasPrefix(algorithm, "ssh-") && !strings.HasPrefix(algorithm, "ecdsa-") && !strings.HasPrefix(algorithm, "sk-") {
		return model.HostKey{}, errors.New("host key file must contain a raw OpenSSH public key, not a known_hosts line")
	}
	public := algorithm + " " + fields[1]
	fp, err := FingerprintPublic(public)
	if err != nil {
		return model.HostKey{}, err
	}
	return model.HostKey{Algorithm: algorithm, PublicKey: fields[1], Fingerprint: fp}, nil
}

func readHostKeyFile(path string) (model.HostKey, error) {
	if err := requireRegularNonSymlink(path, "host public key"); err != nil {
		return model.HostKey{}, err
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return model.HostKey{}, err
	}
	return hostKeyFromPublicLine(string(b))
}

func scanHostKeysForTarget(t target) ([]model.HostKey, error) {
	port := t.Route.Port
	if port == 0 {
		port = 22
	}
	args := []string{"-T", "5", "-p", strconv.Itoa(port), t.Route.Host}
	cmd := exec.Command("ssh-keyscan", args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil && stdout.Len() == 0 {
		return nil, fmt.Errorf("ssh-keyscan %s:%d: %w: %s", t.Route.Host, port, err, strings.TrimSpace(stderr.String()))
	}

	keysByFP := map[string]model.HostKey{}
	s := bufio.NewScanner(bytes.NewReader(stdout.Bytes()))
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		algorithm, blob := fields[len(fields)-2], fields[len(fields)-1]
		key, err := hostKeyFromPublicLine(algorithm + " " + blob)
		if err != nil {
			continue
		}
		keysByFP[key.Fingerprint] = key
	}
	if err := s.Err(); err != nil {
		return nil, err
	}
	if len(keysByFP) == 0 {
		return nil, fmt.Errorf("no SSH host keys returned by %s:%d", t.Route.Host, port)
	}
	keys := make([]model.HostKey, 0, len(keysByFP))
	for _, k := range keysByFP {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].Algorithm == keys[j].Algorithm {
			return keys[i].Fingerprint < keys[j].Fingerprint
		}
		return keys[i].Algorithm < keys[j].Algorithm
	})
	return keys, nil
}

func ScanHostTrust(f *model.Fleet, nodeName, user string) (HostTrustScan, error) {
	t, err := resolveTarget(f, nodeName, user)
	if err != nil {
		return HostTrustScan{}, err
	}
	keys, err := scanHostKeysForTarget(t)
	if err != nil {
		return HostTrustScan{}, err
	}
	return HostTrustScan{Node: nodeName, Username: t.Principal.Username, Route: t.Route, Keys: keys}, nil
}

func VerifyHostTrust(f *model.Fleet, nodeName, user string) (HostTrustVerification, error) {
	t, err := resolveTarget(f, nodeName, user)
	if err != nil {
		return HostTrustVerification{}, err
	}
	if len(t.Node.HostTrust.Keys) == 0 {
		return HostTrustVerification{}, fmt.Errorf("node %s has no pinned host key", nodeName)
	}
	presented, err := scanHostKeysForTarget(t)
	if err != nil {
		return HostTrustVerification{}, err
	}
	trusted := map[string]bool{}
	for _, k := range t.Node.HostTrust.Keys {
		if k.Fingerprint != "" {
			trusted[k.Fingerprint] = true
		}
	}
	matched := []string{}
	for _, k := range presented {
		if trusted[k.Fingerprint] {
			matched = append(matched, k.Fingerprint)
		}
	}
	sort.Strings(matched)
	return HostTrustVerification{
		Node:        nodeName,
		Username:    t.Principal.Username,
		OK:          len(matched) > 0,
		Matched:     matched,
		Presented:   presented,
		TrustedKeys: append([]model.HostKey(nil), t.Node.HostTrust.Keys...),
	}, nil
}

func candidatePresented(candidate model.HostKey, presented []model.HostKey) bool {
	for _, k := range presented {
		if k.Fingerprint == candidate.Fingerprint {
			return true
		}
	}
	return false
}

func TrustHostKey(f *model.Fleet, nodeName, user, keyPath string) (model.HostTrust, error) {
	t, err := resolveTarget(f, nodeName, user)
	if err != nil {
		return model.HostTrust{}, err
	}
	if len(f.Nodes[t.NodeIndex].HostTrust.Keys) != 0 {
		return model.HostTrust{}, fmt.Errorf("node %s already has pinned host trust; use host rotate", nodeName)
	}
	candidate, err := readHostKeyFile(keyPath)
	if err != nil {
		return model.HostTrust{}, err
	}
	presented, err := scanHostKeysForTarget(t)
	if err != nil {
		return model.HostTrust{}, err
	}
	if !candidatePresented(candidate, presented) {
		return model.HostTrust{}, fmt.Errorf("candidate fingerprint %s is not currently presented by %s", candidate.Fingerprint, nodeName)
	}
	now := time.Now().UTC()
	trust := model.HostTrust{Method: "manual-pinned", Keys: []model.HostKey{candidate}, VerifiedAt: &now}
	f.Nodes[t.NodeIndex].HostTrust = trust
	if err := store.Save(f); err != nil {
		return model.HostTrust{}, err
	}
	return trust, nil
}

func RotateHostKey(f *model.Fleet, nodeName, user, expectedOld, keyPath string) (model.HostTrust, error) {
	t, err := resolveTarget(f, nodeName, user)
	if err != nil {
		return model.HostTrust{}, err
	}
	if expectedOld == "" {
		return model.HostTrust{}, errors.New("expected old fingerprint is required")
	}
	foundOld := false
	for _, k := range f.Nodes[t.NodeIndex].HostTrust.Keys {
		if k.Fingerprint == expectedOld {
			foundOld = true
			break
		}
	}
	if !foundOld {
		return model.HostTrust{}, fmt.Errorf("expected old fingerprint %s is not pinned for %s", expectedOld, nodeName)
	}
	candidate, err := readHostKeyFile(keyPath)
	if err != nil {
		return model.HostTrust{}, err
	}
	presented, err := scanHostKeysForTarget(t)
	if err != nil {
		return model.HostTrust{}, err
	}
	if !candidatePresented(candidate, presented) {
		return model.HostTrust{}, fmt.Errorf("candidate fingerprint %s is not currently presented by %s", candidate.Fingerprint, nodeName)
	}

	keys := []model.HostKey{}
	for _, k := range f.Nodes[t.NodeIndex].HostTrust.Keys {
		if k.Fingerprint == expectedOld || k.Algorithm == candidate.Algorithm {
			continue
		}
		keys = append(keys, k)
	}
	keys = append(keys, candidate)
	sort.Slice(keys, func(i, j int) bool { return keys[i].Algorithm < keys[j].Algorithm })
	now := time.Now().UTC()
	trust := model.HostTrust{Method: "manual-rotation", Keys: keys, VerifiedAt: &now}
	f.Nodes[t.NodeIndex].HostTrust = trust
	if err := store.Save(f); err != nil {
		return model.HostTrust{}, err
	}
	return trust, nil
}
