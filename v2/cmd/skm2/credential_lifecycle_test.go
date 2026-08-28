package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/model"
)

func writeTestPublicKey(t *testing.T, dir, name string) string {
	t.Helper()
	priv := filepath.Join(dir, name)
	pub := priv + ".pub"
	if out, err := runCommand("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", name, "-f", priv); err != nil {
		t.Fatalf("ssh-keygen: %v: %s", err, out)
	}
	return pub
}

func runCommand(name string, args ...string) (string, error) {
	cmd := execCommand(name, args...)
	b, err := cmd.CombinedOutput()
	return string(b), err
}

var execCommand = func(name string, args ...string) commandRunner {
	return osExecCommand(name, args...)
}

type commandRunner interface {
	CombinedOutput() ([]byte, error)
}

var osExecCommand = func(name string, args ...string) commandRunner {
	return commandWrapper{name: name, args: args}
}

type commandWrapper struct {
	name string
	args []string
}

func (c commandWrapper) CombinedOutput() ([]byte, error) {
	return exec.Command(c.name, c.args...).CombinedOutput()
}

func TestRotateCredentialMarksPreviousActiveRetiring(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("SKM2_CONFIG_DIR", filepath.Join(dir, "config"))
	oldPub := writeTestPublicKey(t, dir, "old")
	newPub := writeTestPublicKey(t, dir, "new")

	f := &model.Fleet{
		Schema: 2,
		FleetID: "fleet",
		Name: "test",
		Subjects: []model.Subject{{ID: "s", Name: "device", Type: "device", Status: "active"}},
		Credentials: []model.Credential{},
		Policies: []model.Policy{{SubjectID: "s", PrincipalID: "p"}},
	}
	old, err := importCredential(f, "device", oldPub)
	if err != nil { t.Fatal(err) }
	if old.Status != model.CredentialActive { t.Fatalf("old status=%s", old.Status) }

	r, err := rotateCredential(f, "device", newPub)
	if err != nil { t.Fatal(err) }
	if r.NewCredential.Status != model.CredentialActive { t.Fatalf("new status=%s", r.NewCredential.Status) }
	if len(r.Retiring) != 1 || r.Retiring[0].Fingerprint != old.Fingerprint || r.Retiring[0].Status != model.CredentialRetiring {
		t.Fatalf("retiring=%#v", r.Retiring)
	}
}

func TestRetireLastActiveCredentialReferencedByPolicyFails(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("SKM2_CONFIG_DIR", filepath.Join(dir, "config"))
	pub := writeTestPublicKey(t, dir, "only")
	f := &model.Fleet{
		Schema: 2,
		FleetID: "fleet",
		Name: "test",
		Subjects: []model.Subject{{ID: "s", Name: "device", Type: "device", Status: "active"}},
		Policies: []model.Policy{{SubjectID: "s", PrincipalID: "p"}},
	}
	c, err := importCredential(f, "device", pub)
	if err != nil { t.Fatal(err) }
	if _, err := setCredentialLifecycleStatus(f, "device", c.ID, model.CredentialRetired); err == nil {
		t.Fatal("expected last-active retirement refusal")
	}
}
