package remote

import "testing"

func TestHostKeyFromPublicLine(t *testing.T) {
	line := "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEjEd5UkfKJjJ1h6wnb+/2Dbi1jPcKFy5vT3Iu1ALjQ0 test"
	k, err := hostKeyFromPublicLine(line)
	if err != nil {
		t.Fatal(err)
	}
	if k.Algorithm != "ssh-ed25519" || k.PublicKey == "" || k.Fingerprint == "" {
		t.Fatalf("unexpected host key: %#v", k)
	}
}

func TestHostKeyFromKnownHostsLineRefused(t *testing.T) {
	if _, err := hostKeyFromPublicLine("example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEjEd5UkfKJjJ1h6wnb+/2Dbi1jPcKFy5vT3Iu1ALjQ0"); err == nil {
		t.Fatal("expected known_hosts line refusal")
	}
}
