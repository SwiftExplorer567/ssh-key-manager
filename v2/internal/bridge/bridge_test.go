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
	var rev string
	for _, l := range strings.Split(string(out), "\n") {
		if strings.HasPrefix(l, "revision=") {
			rev = strings.TrimPrefix(l, "revision=")
		}
	}
	if rev == "" {
		t.Fatal("missing revision")
	}
	c = exec.Command("sh", script, "apply", rev)
	c.Env = append(os.Environ(), "SKM2_AUTHORIZED_KEYS="+ak)
	c.Stdin = strings.NewReader("new\n")
	if out, err := c.CombinedOutput(); err != nil {
		t.Fatalf("apply: %v %s", err, out)
	}
	c = exec.Command("sh", script, "apply", rev)
	c.Env = append(os.Environ(), "SKM2_AUTHORIZED_KEYS="+ak)
	c.Stdin = strings.NewReader("stale\n")
	if err := c.Run(); err == nil {
		t.Fatal("stale apply unexpectedly succeeded")
	}
}
