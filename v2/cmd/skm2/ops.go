package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/model"
	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/remote"
	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/store"
)

func writeJSONFile(path string, v any) error {
	if path == "" {
		return errors.New("output path required")
	}
	if info, err := os.Lstat(path); err == nil {
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("refusing to replace symlink: %s", path)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".skm2-json-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if err := tmp.Chmod(0600); err != nil {
		_ = tmp.Close()
		return err
	}
	if _, err := tmp.Write(append(b, '\n')); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, path)
}

func readPlan(path string) (model.Plan, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return model.Plan{}, err
	}
	var p model.Plan
	if err := json.Unmarshal(b, &p); err != nil {
		return model.Plan{}, err
	}
	if p.ID == "" || p.FleetRevision == "" || p.ExpectedRevisions == nil {
		return model.Plan{}, errors.New("invalid SKM V2 plan")
	}
	return p, nil
}

func findSubjectIndex(f *model.Fleet, name string) (int, error) {
	for i := range f.Subjects {
		if f.Subjects[i].Name == name {
			return i, nil
		}
	}
	return -1, fmt.Errorf("subject not found: %s", name)
}

func findPrincipalIndex(f *model.Fleet, nodeName, user string) (int, int, error) {
	for ni := range f.Nodes {
		if f.Nodes[ni].Name != nodeName {
			continue
		}
		if user == "" {
			if len(f.Nodes[ni].Principals) != 1 {
				return -1, -1, fmt.Errorf("node %s has %d principals; specify --user", nodeName, len(f.Nodes[ni].Principals))
			}
			return ni, 0, nil
		}
		for pi := range f.Nodes[ni].Principals {
			if f.Nodes[ni].Principals[pi].Username == user {
				return ni, pi, nil
			}
		}
		return -1, -1, fmt.Errorf("principal %s not found on node %s", user, nodeName)
	}
	return -1, -1, fmt.Errorf("node not found: %s", nodeName)
}

func addSubject(f *model.Fleet, name, kind string) (*model.Subject, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return nil, errors.New("subject name required")
	}
	if _, err := findSubjectIndex(f, name); err == nil {
		return nil, fmt.Errorf("subject already exists: %s", name)
	}
	if kind == "" {
		kind = "device"
	}
	f.Subjects = append(f.Subjects, model.Subject{ID: store.NewID("subject"), Name: name, Type: kind, Status: "active"})
	if err := store.Save(f); err != nil {
		return nil, err
	}
	return &f.Subjects[len(f.Subjects)-1], nil
}

func importCredential(f *model.Fleet, subjectName, pubPath string) (*model.Credential, error) {
	si, err := findSubjectIndex(f, subjectName)
	if err != nil {
		return nil, err
	}
	if info, err := os.Lstat(pubPath); err != nil {
		return nil, err
	} else if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return nil, fmt.Errorf("public key must be a regular non-symlink file: %s", pubPath)
	}
	b, err := os.ReadFile(pubPath)
	if err != nil {
		return nil, err
	}
	fields := strings.Fields(string(b))
	if len(fields) < 2 {
		return nil, errors.New("invalid OpenSSH public key")
	}
	publicKey := fields[0] + " " + fields[1]
	fp, err := remote.FingerprintPublic(publicKey)
	if err != nil {
		return nil, err
	}
	for i := range f.Credentials {
		if f.Credentials[i].Fingerprint != fp {
			continue
		}
		if f.Credentials[i].SubjectID != f.Subjects[si].ID {
			return nil, fmt.Errorf("credential %s already belongs to another subject", fp)
		}
		f.Credentials[i].PublicKey = publicKey
		f.Credentials[i].Algorithm = fields[0]
		if f.Credentials[i].Status == "" {
			f.Credentials[i].Status = model.CredentialActive
		}
		if err := store.Save(f); err != nil {
			return nil, err
		}
		return &f.Credentials[i], nil
	}
	f.Credentials = append(f.Credentials, model.Credential{
		ID:          store.NewID("cred"),
		SubjectID:   f.Subjects[si].ID,
		Fingerprint: fp,
		Algorithm:   fields[0],
		Status:      model.CredentialActive,
		PublicKey:   publicKey,
	})
	if err := store.Save(f); err != nil {
		return nil, err
	}
	return &f.Credentials[len(f.Credentials)-1], nil
}

func grantPolicy(f *model.Fleet, subjectName, nodeName, user string) (*model.Policy, error) {
	si, err := findSubjectIndex(f, subjectName)
	if err != nil {
		return nil, err
	}
	ni, pi, err := findPrincipalIndex(f, nodeName, user)
	if err != nil {
		return nil, err
	}
	sid := f.Subjects[si].ID
	pid := f.Nodes[ni].Principals[pi].ID
	for i := range f.Policies {
		if f.Policies[i].SubjectID == sid && f.Policies[i].PrincipalID == pid {
			return &f.Policies[i], nil
		}
	}
	f.Policies = append(f.Policies, model.Policy{SubjectID: sid, PrincipalID: pid})
	if err := store.Save(f); err != nil {
		return nil, err
	}
	return &f.Policies[len(f.Policies)-1], nil
}

func revokePolicy(f *model.Fleet, subjectName, nodeName, user string) error {
	si, err := findSubjectIndex(f, subjectName)
	if err != nil {
		return err
	}
	ni, pi, err := findPrincipalIndex(f, nodeName, user)
	if err != nil {
		return err
	}
	sid := f.Subjects[si].ID
	pid := f.Nodes[ni].Principals[pi].ID
	out := f.Policies[:0]
	removed := false
	for _, p := range f.Policies {
		if p.SubjectID == sid && p.PrincipalID == pid {
			removed = true
			continue
		}
		out = append(out, p)
	}
	if !removed {
		return errors.New("policy grant not found")
	}
	f.Policies = out
	return store.Save(f)
}

func setPolicyMode(f *model.Fleet, nodeName, user, mode string) (*model.Principal, error) {
	ni, pi, err := findPrincipalIndex(f, nodeName, user)
	if err != nil {
		return nil, err
	}
	var m model.PolicyMode
	switch model.PolicyMode(mode) {
	case model.PolicyObserve, model.PolicyAdditive, model.PolicyAuthoritative:
		m = model.PolicyMode(mode)
	default:
		return nil, fmt.Errorf("invalid policy mode %q (want observe, additive or authoritative)", mode)
	}
	f.Nodes[ni].Principals[pi].PolicyMode = m
	if err := store.Save(f); err != nil {
		return nil, err
	}
	return &f.Nodes[ni].Principals[pi], nil
}
