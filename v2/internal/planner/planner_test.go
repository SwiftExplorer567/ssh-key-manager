package planner

import (
	"testing"

	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/model"
)

func TestAuthoritativePreservesUnmanaged(t *testing.T) {
	f := &model.Fleet{Revision: "r", Subjects: []model.Subject{{ID: "s", Name: "laptop"}}, Credentials: []model.Credential{{ID: "c", SubjectID: "s", Fingerprint: "SHA256:new", Status: model.CredentialActive}}, Nodes: []model.Node{{ID: "n", Name: "server", Principals: []model.Principal{{ID: "p", Username: "root", PolicyMode: model.PolicyAuthoritative}}}}, Policies: []model.Policy{{SubjectID: "s", PrincipalID: "p"}}}
	p := Build(f, []model.ObservedPrincipal{{PrincipalID: "p", Revision: "x", Grants: []model.Grant{{Fingerprint: "SHA256:unknown", Managed: false}}}})
	if len(p.Changes) != 1 || p.Changes[0].Action != "grant" {
		t.Fatalf("unexpected changes: %#v", p.Changes)
	}
	if len(p.Warnings) == 0 {
		t.Fatal("expected unmanaged warning")
	}
}

func TestUnobservedPrincipalNeverProducesChanges(t *testing.T) {
	f := &model.Fleet{
		Revision:    "r",
		Subjects:    []model.Subject{{ID: "s", Name: "laptop"}},
		Credentials: []model.Credential{{ID: "c", SubjectID: "s", Fingerprint: "SHA256:new", Status: model.CredentialActive}},
		Nodes:       []model.Node{{ID: "n", Name: "server", Principals: []model.Principal{{ID: "p", Username: "root", PolicyMode: model.PolicyAuthoritative}}}},
		Policies:    []model.Policy{{SubjectID: "s", PrincipalID: "p"}},
	}
	p := Build(f, nil)
	if len(p.Changes) != 0 {
		t.Fatalf("unobserved principal produced changes: %#v", p.Changes)
	}
	if len(p.Warnings) != 1 {
		t.Fatalf("expected one unobserved warning, got %#v", p.Warnings)
	}
}
