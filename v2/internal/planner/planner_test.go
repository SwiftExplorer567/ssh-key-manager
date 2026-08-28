package planner

import (
	"strings"
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

func TestSingleObservedPrincipalScopesPlan(t *testing.T) {
	f := &model.Fleet{
		Revision:    "r",
		Subjects:    []model.Subject{{ID: "s", Name: "laptop"}},
		Credentials: []model.Credential{{ID: "c", SubjectID: "s", Fingerprint: "SHA256:new", Status: model.CredentialActive}},
		Nodes: []model.Node{
			{ID: "n1", Name: "one", Principals: []model.Principal{{ID: "p1", Username: "root", PolicyMode: model.PolicyAdditive}}},
			{ID: "n2", Name: "two", Principals: []model.Principal{{ID: "p2", Username: "root", PolicyMode: model.PolicyAdditive}}},
		},
		Policies: []model.Policy{{SubjectID: "s", PrincipalID: "p1"}, {SubjectID: "s", PrincipalID: "p2"}},
	}
	p := Build(f, []model.ObservedPrincipal{{PrincipalID: "p1", Revision: "x"}})
	if len(p.Changes) != 1 || p.Changes[0].PrincipalID != "p1" {
		t.Fatalf("unexpected scoped changes: %#v", p.Changes)
	}
	for _, w := range p.Warnings {
		if strings.Contains(w, "p2") || strings.Contains(w, "two") {
			t.Fatalf("unrelated principal leaked into scoped warnings: %#v", p.Warnings)
		}
	}
}

func TestMultipleObservationsRetainFleetWarnings(t *testing.T) {
	f := &model.Fleet{
		Revision: "r",
		Nodes: []model.Node{
			{ID: "n1", Name: "one", Principals: []model.Principal{{ID: "p1", Username: "root", PolicyMode: model.PolicyObserve}}},
			{ID: "n2", Name: "two", Principals: []model.Principal{{ID: "p2", Username: "root", PolicyMode: model.PolicyObserve}}},
			{ID: "n3", Name: "three", Principals: []model.Principal{{ID: "p3", Username: "root", PolicyMode: model.PolicyObserve}}},
		},
	}
	p := Build(f, []model.ObservedPrincipal{{PrincipalID: "p1", Revision: "x"}, {PrincipalID: "p2", Revision: "y"}})
	if len(p.Warnings) != 1 || !strings.Contains(p.Warnings[0], "p3") {
		t.Fatalf("expected missing p3 warning, got %#v", p.Warnings)
	}
}
