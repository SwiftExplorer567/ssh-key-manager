package migrate

import (
	"os"
	"path/filepath"
	"testing"
)

func TestV1MigrationIsMetadataOnly(t *testing.T) {
	d := t.TempDir()
	os.WriteFile(filepath.Join(d, "servers.conf"), []byte("rpi5|root|192.0.2.1|22\n"), 0600)
	os.WriteFile(filepath.Join(d, "identities.conf"), []byte("laptop|SHA256:abc|device|active\n"), 0600)
	os.WriteFile(filepath.Join(d, "policy.conf"), []byte("SHA256:abc|rpi5\n"), 0600)
	r, e := FromV1(d, "x")
	if e != nil {
		t.Fatal(e)
	}
	if len(r.Fleet.Nodes) != 1 || len(r.Fleet.Subjects) != 1 || len(r.Fleet.Policies) != 1 {
		t.Fatalf("unexpected migration %#v", r.Fleet)
	}
}
