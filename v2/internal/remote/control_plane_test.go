package remote

import (
	"testing"

	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/model"
)

func TestSplitControlPlaneGrants(t *testing.T) {
	in := model.ObservedPrincipal{
		PrincipalID: "principal_test",
		Revision:    "rev",
		Grants: []model.Grant{
			{Fingerprint: "SHA256:user", Managed: false},
			{Fingerprint: "SHA256:control", Managed: false},
		},
	}
	out, control := splitControlPlaneGrants(in, "SHA256:control")
	if len(out.Grants) != 1 || out.Grants[0].Fingerprint != "SHA256:user" {
		t.Fatalf("unexpected user grants: %#v", out.Grants)
	}
	if len(control) != 1 || control[0] != "SHA256:control" {
		t.Fatalf("unexpected control-plane grants: %#v", control)
	}
	if out.Revision != in.Revision || out.PrincipalID != in.PrincipalID {
		t.Fatalf("principal metadata changed: %#v", out)
	}
}
