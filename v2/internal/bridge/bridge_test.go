package bridge

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestBridgeRevisionGuard(t *testing.T) {
	d := t.TempDir()
	ak := filepath.Join(d, "authorized_keys")
	if err := os.WriteFile(ak, []byte("old\n"), 0600); err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(d, "bridge.sh")
	if err := os.WriteFile(script, []byte(Script), 0700); err != nil {
		t.Fatal(err)
	}
	c := exec.Command("sh", script, "inspect")
	c.Env = append(os.Environ(), "SKM2_AUTHORIZED_KEYS="+ak)
	out, err := c.Output()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(string(out), "SKM2-STATE|3\n") {
		t.Fatalf("unexpected inspect header: %s", out)
	}
	var rev string
	for _, l := range strings.Split(string(out), "\n") {
		if strings.HasPrefix(l, "revision=") {
			rev = strings.TrimPrefix(l, "revision=")
		}
	}
	if rev == "" {
		t.Fatal("missing revision")
	}
	c = exec.Command("sh", script, "apply", rev, "op_test")
	c.Env = append(os.Environ(), "SKM2_AUTHORIZED_KEYS="+ak)
	c.Stdin = strings.NewReader("new\n")
	applied, err := c.CombinedOutput()
	if err != nil {
		t.Fatalf("apply: %v %s", err, applied)
	}
	if !strings.Contains(string(applied), "operation=op_test") {
		t.Fatalf("missing apply operation receipt: %s", applied)
	}

	c = exec.Command("sh", script, "inspect")
	c.Env = append(os.Environ(), "SKM2_AUTHORIZED_KEYS="+ak)
	out, err = c.Output()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(out), "last_operation=op_test") || !strings.Contains(string(out), "last_before="+rev) {
		t.Fatalf("inspect missing committed receipt: %s", out)
	}

	c = exec.Command("sh", script, "apply", rev, "op_stale")
	c.Env = append(os.Environ(), "SKM2_AUTHORIZED_KEYS="+ak)
	c.Stdin = strings.NewReader("stale\n")
	if err := c.Run(); err == nil {
		t.Fatal("stale apply unexpectedly succeeded")
	}
}
