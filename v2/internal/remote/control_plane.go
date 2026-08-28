package remote

import (
	"encoding/json"

	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/model"
)

type inspectionJSON struct {
	NodeName                 string                  `json:"node_name"`
	Username                 string                  `json:"username"`
	Observed                 model.ObservedPrincipal `json:"observed"`
	ManagedFingerprints      []string                `json:"managed_fingerprints"`
	ControlPlaneFingerprints []string                `json:"control_plane_fingerprints"`
}

func splitControlPlaneGrants(observed model.ObservedPrincipal, controlFP string) (model.ObservedPrincipal, []string) {
	out := observed
	out.Grants = make([]model.Grant, 0, len(observed.Grants))
	control := []string{}
	for _, grant := range observed.Grants {
		if controlFP != "" && grant.Fingerprint == controlFP {
			control = append(control, grant.Fingerprint)
			continue
		}
		out.Grants = append(out.Grants, grant)
	}
	return out, control
}

func userAccessProjection(in Inspection) (model.ObservedPrincipal, []string) {
	controlFP := ""
	if path, err := ManagedKeyPath(); err == nil {
		if _, fp, err := loadManagedPublic(path); err == nil {
			controlFP = fp
		}
	}
	return splitControlPlaneGrants(in.Observed, controlFP)
}

// UserObserved returns the authorization view used by the policy planner.
// The enrolled controller credential is transport/control-plane state, not a
// user-access grant, so it must never create access drift warnings or changes.
func UserObserved(in Inspection) model.ObservedPrincipal {
	observed, _ := userAccessProjection(in)
	return observed
}

// MarshalJSON keeps the enrolled controller credential out of the user-access
// grant list while exposing it explicitly as control-plane state. The key still
// participates in the remote authorized_keys revision and is preserved by
// reconciliation; only its access-policy classification is separated.
func (in Inspection) MarshalJSON() ([]byte, error) {
	observed, control := userAccessProjection(in)
	return json.Marshal(inspectionJSON{
		NodeName:                 in.NodeName,
		Username:                 in.Username,
		Observed:                 observed,
		ManagedFingerprints:      in.ManagedFingerprints,
		ControlPlaneFingerprints: control,
	})
}
