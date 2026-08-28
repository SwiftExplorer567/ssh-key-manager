package remote

import (
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/model"
	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/store"
)

const mutationReceiptCapability = "mutation-receipts-v1"

type mutationState struct {
	Revision      string
	LastOperation string
	LastKind      string
	LastBefore    string
	LastAfter     string
}

type appliedStage struct {
	stage  stagedApply
	result ApplyResult
}

func parseMutationState(raw string) (mutationState, error) {
	state := mutationState{}
	lines := strings.Split(strings.ReplaceAll(raw, "\r\n", "\n"), "\n")
	if len(lines) == 0 || lines[0] != "SKM2-STATE|2" {
		return state, errors.New("invalid bridge inspect response")
	}
	for _, line := range lines[1:] {
		if line == "--" {
			break
		}
		switch {
		case strings.HasPrefix(line, "revision="):
			state.Revision = strings.TrimPrefix(line, "revision=")
		case strings.HasPrefix(line, "last_operation="):
			state.LastOperation = strings.TrimPrefix(line, "last_operation=")
		case strings.HasPrefix(line, "last_kind="):
			state.LastKind = strings.TrimPrefix(line, "last_kind=")
		case strings.HasPrefix(line, "last_before="):
			state.LastBefore = strings.TrimPrefix(line, "last_before=")
		case strings.HasPrefix(line, "last_after="):
			state.LastAfter = strings.TrimPrefix(line, "last_after=")
		}
	}
	if state.Revision == "" {
		return state, errors.New("bridge inspect response missing revision")
	}
	return state, nil
}

func parseMutationResponse(raw, expectedOperation string) (string, error) {
	operation := ""
	revision := ""
	lines := strings.Split(strings.ReplaceAll(raw, "\r\n", "\n"), "\n")
	if len(lines) == 0 || lines[0] != "SKM2-APPLIED|2" {
		return "", errors.New("invalid bridge apply response")
	}
	for _, line := range lines[1:] {
		if strings.HasPrefix(line, "operation=") {
			operation = strings.TrimPrefix(line, "operation=")
		}
		if strings.HasPrefix(line, "revision=") {
			revision = strings.TrimPrefix(line, "revision=")
		}
	}
	if operation != expectedOperation {
		return "", fmt.Errorf("mutation operation mismatch: expected=%s got=%s", expectedOperation, operation)
	}
	if revision == "" {
		return "", errors.New("mutation response missing revision")
	}
	return revision, nil
}

func inspectMutationState(t target, key string) (mutationState, error) {
	out, _, err := runSSH(t, key, true, nil, "inspect")
	if err != nil {
		return mutationState{}, err
	}
	return parseMutationState(out)
}

func requireMutationReceipts(t target, key string) error {
	out, _, err := runSSH(t, key, true, nil, "capabilities")
	if err != nil {
		return fmt.Errorf("target %s/%s does not expose beta.2 mutation receipts; re-enroll the node before fleet apply: %w", t.Node.Name, t.Principal.Username, err)
	}
	found := false
	for _, line := range strings.Split(strings.ReplaceAll(out, "\r\n", "\n"), "\n") {
		if strings.TrimSpace(line) == mutationReceiptCapability {
			found = true
			break
		}
	}
	if !found {
		return fmt.Errorf("target %s/%s does not advertise %s; re-enroll the node before fleet apply", t.Node.Name, t.Principal.Username, mutationReceiptCapability)
	}
	return nil
}

func receiptProvesMutation(state mutationState, operation, kind, before string) bool {
	return state.LastOperation == operation &&
		state.LastKind == kind &&
		state.LastBefore == before &&
		state.LastAfter != "" &&
		state.Revision == state.LastAfter
}

func performReceiptRollback(key string, a appliedStage) (string, error) {
	operation := store.NewID("op")
	out, _, runErr := runSSH(a.stage.target, key, true, nil, "rollback", a.result.NewRevision, operation)
	if runErr == nil {
		if restored, parseErr := parseMutationResponse(out, operation); parseErr == nil {
			return restored, nil
		} else {
			runErr = parseErr
		}
	}

	state, inspectErr := inspectMutationState(a.stage.target, key)
	if inspectErr != nil {
		return "", fmt.Errorf("rollback response uncertain (%v) and receipt inspection failed: %w", runErr, inspectErr)
	}
	if receiptProvesMutation(state, operation, "rollback", a.result.NewRevision) {
		return state.LastAfter, nil
	}
	return "", fmt.Errorf("rollback was not proven by receipt after error: %v (current=%s last_operation=%s)", runErr, state.Revision, state.LastOperation)
}

func rollbackAppliedStages(key string, applied []appliedStage) []string {
	failures := []string{}
	for i := len(applied) - 1; i >= 0; i-- {
		a := applied[i]
		restoredRevision, err := performReceiptRollback(key, a)
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

func abortFleetApply(key string, applied []appliedStage, current stagedApply, operation string, cause error) error {
	state, inspectErr := inspectMutationState(current.target, key)
	currentCommitted := false
	currentAmbiguous := false
	if inspectErr == nil {
		if receiptProvesMutation(state, operation, "apply", current.expected) {
			currentCommitted = true
			applied = append(applied, appliedStage{stage: current, result: ApplyResult{
				PrincipalID: current.target.Principal.ID,
				Node:        current.target.Node.Name,
				Username:    current.target.Principal.Username,
				OldRevision: current.expected,
				NewRevision: state.LastAfter,
			}})
		} else if state.Revision != current.expected {
			// A changed revision without our receipt may be a concurrent/manual edit.
			// Never guess that the bridge backup belongs to us and roll it back.
			currentAmbiguous = true
		}
	} else {
		currentAmbiguous = true
	}

	rollbackFailures := rollbackAppliedStages(key, applied)
	if len(rollbackFailures) > 0 || currentAmbiguous {
		details := []string{}
		if currentAmbiguous {
			if inspectErr != nil {
				details = append(details, fmt.Sprintf("current target state could not be verified: %v", inspectErr))
			} else {
				details = append(details, fmt.Sprintf("current target revision changed without matching operation receipt (current=%s last_operation=%s)", state.Revision, state.LastOperation))
			}
		}
		details = append(details, rollbackFailures...)
		return fmt.Errorf("apply failed on %s/%s: %v; AUTOMATIC ROLLBACK INCOMPLETE: %s", current.target.Node.Name, current.target.Principal.Username, cause, strings.Join(details, "; "))
	}

	rolledBack := len(applied)
	if currentCommitted {
		return fmt.Errorf("apply response failed on %s/%s after its receipt proved commit: %v; automatic rollback completed for %d target(s)", current.target.Node.Name, current.target.Principal.Username, cause, rolledBack)
	}
	return fmt.Errorf("apply failed on %s/%s before a matching commit receipt: %v; automatic rollback completed for %d previously applied target(s)", current.target.Node.Name, current.target.Principal.Username, cause, rolledBack)
}

// ApplyPlanSafe performs full-fleet preflight and requires the receipt extension
// on every participating target before the first mutation. If a later target
// fails, confirmed mutations are restored in reverse order. A target is never
// automatically rolled back merely because its revision changed: its own
// operation receipt must prove that this controller committed the mutation.
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
		if err := requireMutationReceipts(t, key); err != nil {
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
		operation := store.NewID("op")
		args := []string{"apply", s.expected, operation}
		args = append(args, s.managed...)
		appliedOut, _, runErr := runSSH(s.target, key, true, s.content, args...)
		if runErr != nil {
			return nil, abortFleetApply(key, applied, s, operation, runErr)
		}
		newRevision, parseErr := parseMutationResponse(appliedOut, operation)
		if parseErr != nil {
			return nil, abortFleetApply(key, applied, s, operation, parseErr)
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
			"operation_id": operation,
			"principal_id": s.target.Principal.ID,
			"node":         s.target.Node.Name,
			"username":     s.target.Principal.Username,
			"old_revision": s.expected,
			"new_revision": newRevision,
		})
	}
	return results, nil
}
