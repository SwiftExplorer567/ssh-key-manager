package planner

import (
	"fmt"
	"sort"
	"time"

	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/model"
	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/store"
)

func Build(f *model.Fleet, observed []model.ObservedPrincipal) model.Plan {
	p := model.Plan{
		ID:                store.NewID("plan"),
		FleetRevision:     f.Revision,
		CreatedAt:         time.Now().UTC(),
		ExpectedRevisions: map[string]string{},
		Changes:           []model.Change{},
		Warnings:          []string{},
	}
	obs := map[string]model.ObservedPrincipal{}
	for _, o := range observed {
		obs[o.PrincipalID] = o
		p.ExpectedRevisions[o.PrincipalID] = o.Revision
	}

	// A single observation is an explicitly scoped plan (for example
	// `skm2 plan --node NAME`). Do not emit unrelated fleet warnings for
	// principals the caller intentionally did not inspect. Multi-principal
	// and empty observation sets retain the fleet-wide missing-observation
	// warnings because they represent broader planning inputs.
	scopedPrincipalID := ""
	if len(observed) == 1 {
		scopedPrincipalID = observed[0].PrincipalID
	}

	subjCred := map[string][]model.Credential{}
	for _, c := range f.Credentials {
		if c.Status == model.CredentialActive || c.Status == model.CredentialRetiring {
			subjCred[c.SubjectID] = append(subjCred[c.SubjectID], c)
		}
	}
	expected := map[string]map[string]model.Credential{}
	for _, rule := range f.Policies {
		if expected[rule.PrincipalID] == nil {
			expected[rule.PrincipalID] = map[string]model.Credential{}
		}
		for _, c := range subjCred[rule.SubjectID] {
			expected[rule.PrincipalID][c.Fingerprint] = c
		}
	}
	for _, n := range f.Nodes {
		for _, pr := range n.Principals {
			if scopedPrincipalID != "" && pr.ID != scopedPrincipalID {
				continue
			}
			o, observedOK := obs[pr.ID]
			if !observedOK {
				p.Warnings = append(p.Warnings, fmt.Sprintf("principal %s on %s was not observed; no changes planned", pr.ID, n.Name))
				continue
			}
			actual := map[string]model.Grant{}
			for _, g := range o.Grants {
				actual[g.Fingerprint] = g
			}
			for fp, c := range expected[pr.ID] {
				if _, ok := actual[fp]; !ok {
					p.Changes = append(p.Changes, model.Change{Action: "grant", PrincipalID: pr.ID, SubjectID: c.SubjectID, CredentialID: c.ID, Fingerprint: fp, Reason: "expected by policy"})
				}
			}
			for fp, g := range actual {
				if _, ok := expected[pr.ID][fp]; ok {
					continue
				}
				switch pr.PolicyMode {
				case model.PolicyAuthoritative:
					if g.Managed {
						p.Changes = append(p.Changes, model.Change{Action: "revoke", PrincipalID: pr.ID, SubjectID: g.SubjectID, CredentialID: g.CredentialID, Fingerprint: fp, Reason: "managed grant not in authoritative policy"})
					} else {
						p.Warnings = append(p.Warnings, fmt.Sprintf("unmanaged credential %s on %s preserved", fp, pr.ID))
					}
				case model.PolicyAdditive:
					p.Warnings = append(p.Warnings, fmt.Sprintf("extra credential %s on %s preserved", fp, pr.ID))
				}
			}
		}
	}
	sort.Slice(p.Changes, func(i, j int) bool {
		if p.Changes[i].PrincipalID == p.Changes[j].PrincipalID {
			return p.Changes[i].Fingerprint < p.Changes[j].Fingerprint
		}
		return p.Changes[i].PrincipalID < p.Changes[j].PrincipalID
	})
	return p
}
