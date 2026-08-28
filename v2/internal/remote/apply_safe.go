package remote

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/model"
	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/store"
)

type appliedStage struct {
	stage stagedApply
	result ApplyResult
}

func rollbackAppliedStages(key string, applied []appliedStage) []string {
	failures := []string{}
	for i := len(applied) - 1; i >= 0; i-- {
		a := applied[i]
		out, _, err := runSSH(a.stage.target, key, true, nil, "rollback", a.result.NewRevision)
		if err != nil {
			failures = append(failures, fmt.Sprintf("%s/%s: %v", a.stage.target.Node.Name, a.stage.target.Principal.Username, err))
			continue
		}
		restoredRevision, err := parseApplied(out)
		if err != nil {
			failures = append(failures, fmt.Sprintf("%s/%s: %v", a.stage.target.Node.Name, a.stage.target.Principal.Username, err))
			continue
		}
		_ = store.AppendHistory(map[string]any{
			"time":              time.Now().UTC(),
			"operation":         "auto-rollback",
			"principal_id":      a.stage.target.Principal.ID,
			"node":              a.stage.target.Node.Name,
			"username":          a.stage.target.Principal.Username,
			"failed_apply_rev":  a.result.NewRevision,
			"restored_revision": restoredRevision,
		})
	}
	return failures
}

// ApplyPlanSafe performs the same full-fleet preflight as ApplyPlan, but if a
// later target fails after earlier targets were mutated it attempts to restore
// every already-applied target in reverse order. Each target is mutated at most
// once per plan, matching the bridge's single-step rollback backup semantics.
func ApplyPlanSafe(f *model.Fleet, p model.Plan) ([]ApplyResult, error) {
	if p.FleetRevision == "" || p.FleetRevision != f.Revision {
		return nil, fmt.Errorf("fleet revision mismatch: plan=%s current=%s", p.FleetRevision, f.Revision)
	}

	changesByPrincipal := map[string][]model.Change{}
	for _, c := range p.Changes {
		changesByPrincipal[c.PrincipalID] = append(changesByPrincipal[c.PrincipalID], c)
	}
	principalIDs := make([]string, 0, len(changesByPrincipal))
	for id := range changesByPrincipal {
		principalIDs = append(principalIDs, id)
	}
	sort.Strings(principalIDs)
	if len(principalIDs) == 0 {
		return []ApplyResult{}, nil
	}

	key, err := ManagedKeyPath()
	if err != nil {
		return nil, err
	}
	if err := requireRegularNonSymlink(key, "managed key"); err != nil {
		return nil, err
	}

	staged := make([]stagedApply, 0, len(principalIDs))
	for _, pid := range principalIDs {
		t, err := resolvePrincipalID(f, pid)
		if err != nil {
			return nil, err
		}
		inspectOut, _, err := runSSH(t, key, true, nil, "inspect")
		if err != nil {
			return nil, err
		}
		inspection, _, err := parseInspection(f, t, inspectOut)
		if err != nil {
			return nil, err
		}
		expected, ok := p.ExpectedRevisions[pid]
		if !ok || expected == "" {
			return nil, fmt.Errorf("plan has no observed revision for principal %s", pid)
		}
		if inspection.Observed.Revision != expected {
			return nil, fmt.Errorf("remote revision mismatch for %s: plan=%s current=%s", pid, expected, inspection.Observed.Revision)
		}
		content, managed, err := renderChanges(f, inspection, changesByPrincipal[pid])
		if err != nil {
			return nil, err
		}
		staged = append(staged, stagedApply{target: t, expected: expected, content: content, managed: managed})
	}

	results := []ApplyResult{}
	applied := []appliedStage{}
	for _, s := range staged {
		args := []string{"apply", s.expected}
		args = append(args, s.managed...)
		appliedOut, _, applyErr := runSSH(s.target, key, true, s.content, args...)
		if applyErr != nil {
			rollbackFailures := rollbackAppliedStages(key, applied)
			if len(rollbackFailures) > 0 {
				return results, fmt.Errorf("apply failed on %s/%s: %v; AUTOMATIC ROLLBACK INCOMPLETE: %s", s.target.Node.Name, s.target.Principal.Username, applyErr, strings.Join(rollbackFailures, "; "))
			}
			return nil, fmt.Errorf("apply failed on %s/%s: %v; automatic rollback completed for %d previously applied target(s)", s.target.Node.Name, s.target.Principal.Username, applyErr, len(applied))
		}
		newRevision, parseErr := parseApplied(appliedOut)
		if parseErr != nil {
			rollbackFailures := rollbackAppliedStages(key, applied)
			if len(rollbackFailures) > 0 {
				return results, fmt.Errorf("apply response invalid on %s/%s: %v; AUTOMATIC ROLLBACK INCOMPLETE: %s", s.target.Node.Name, s.target.Principal.Username, parseErr, strings.Join(rollbackFailures, "; "))
			}
			return nil, fmt.Errorf("apply response invalid on %s/%s: %v; automatic rollback completed for %d previously applied target(s)", s.target.Node.Name, s.target.Principal.Username, parseErr, len(applied))
		}
		r := ApplyResult{
			PrincipalID: s.target.Principal.ID,
			Node:        s.target.Node.Name,
			Username:    s.target.Principal.Username,
			OldRevision: s.expected,
			NewRevision: newRevision,
		}
		results = append(results, r)
		applied = append(applied, appliedStage{stage: s, result: r})
		_ = store.AppendHistory(map[string]any{
			"time":         time.Now().UTC(),
			"operation":    "apply",
			"plan_id":      p.ID,
			"principal_id": s.target.Principal.ID,
			"node":         s.target.Node.Name,
			"username":     s.target.Principal.Username,
			"old_revision": s.expected,
			"new_revision": newRevision,
		})
	}
	return results, nil
}
