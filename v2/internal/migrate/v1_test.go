package migrate

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
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
	if r.Fleet.Policies == nil || r.Warnings == nil {
		t.Fatal("empty collections must serialize as [] instead of null")
	}
}

func TestV1MigrationDeterministicAndPreservesHostTrust(t *testing.T) {
	if _, err := exec.LookPath("ssh-keygen"); err != nil {
		t.Skip("ssh-keygen unavailable")
	}
	d := t.TempDir()
	keyPath := filepath.Join(d, "host")
	cmd := exec.Command("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", keyPath)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("ssh-keygen: %v: %s", err, out)
	}
	pub, err := os.ReadFile(keyPath + ".pub")
	if err != nil {
		t.Fatal(err)
	}
	fields := strings.Fields(string(pub))
	if len(fields) < 2 {
		t.Fatal("unexpected generated public key")
	}

	os.WriteFile(filepath.Join(d, "servers.conf"), []byte("rpi5|root|192.0.2.1|22\n"), 0600)
	os.WriteFile(filepath.Join(d, "identities.conf"), []byte("laptop|SHA256:abc|device|active\n"), 0600)
	os.WriteFile(filepath.Join(d, "policy.conf"), []byte("SHA256:abc|rpi5\n"), 0600)
	os.WriteFile(filepath.Join(d, "known_hosts"), []byte("192.0.2.1 "+fields[0]+" "+fields[1]+"\n"), 0600)

	first, err := FromV1(d, "x")
	if err != nil {
		t.Fatal(err)
	}
	second, err := FromV1(d, "x")
	if err != nil {
		t.Fatal(err)
	}

	if first.Fleet.FleetID != second.Fleet.FleetID ||
		first.Fleet.Nodes[0].ID != second.Fleet.Nodes[0].ID ||
		first.Fleet.Nodes[0].Principals[0].ID != second.Fleet.Nodes[0].Principals[0].ID ||
		first.Fleet.Nodes[0].Principals[0].Routes[0].ID != second.Fleet.Nodes[0].Principals[0].Routes[0].ID ||
		first.Fleet.Subjects[0].ID != second.Fleet.Subjects[0].ID ||
		first.Fleet.Credentials[0].ID != second.Fleet.Credentials[0].ID {
		t.Fatal("repeated migration must produce stable IDs")
	}

	nodeID := first.Fleet.Nodes[0].ID
	routeID := first.Fleet.Nodes[0].Principals[0].Routes[0].ID
	nodeSuffix := strings.TrimPrefix(nodeID, "node_")
	routeSuffix := strings.TrimPrefix(routeID, "route_")
	if nodeSuffix == routeSuffix {
		t.Fatalf("stable ID namespaces must be domain-separated: node=%s route=%s", nodeID, routeID)
	}

	trust := first.Fleet.Nodes[0].HostTrust
	if trust.Method != "v1-pinned" || len(trust.Keys) != 1 {
		t.Fatalf("expected migrated host trust, got %#v", trust)
	}
	if trust.Keys[0].Algorithm != fields[0] || trust.Keys[0].PublicKey != fields[1] || !strings.HasPrefix(trust.Keys[0].Fingerprint, "SHA256:") {
		t.Fatalf("unexpected migrated host key %#v", trust.Keys[0])
	}
}
