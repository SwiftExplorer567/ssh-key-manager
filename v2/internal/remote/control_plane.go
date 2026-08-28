package remote

import (
	"encoding/json"

	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/model"
)

type inspectionJSON struct {
	NodeName                  string                  `json:"node_name"`
	Username                  string                  `json:"username"`
	Observed                  model.ObservedPrincipal `json:"observed"`
	ManagedFingerprints       []string                `json:"managed_fingerprints"`
	ControlPlaneFingerprints  []string                `json:"control_plane_fingerprints"`
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

// MarshalJSON keeps the enrolled controller credential out of the user-access
// grant list. The key remains part of the remote authorized_keys revision and is
// still preserved by reconciliation; this is presentation-only separation so
// users do not mistake the control-plane channel for application access drift.
func (in Inspection) MarshalJSON() ([]byte, error) {
	controlFP := ""
	if path, err := ManagedKeyPath(); err == nil {
		if _, fp, err := loadManagedPublic(path); err == nil {
			controlFP = fp
		}
	}
	observed, control := splitControlPlaneGrants(in.Observed, controlFP)
	return json.Marshal(inspectionJSON{
		NodeName:                 in.NodeName,
		Username:                 in.Username,
		Observed:                 observed,
		ManagedFingerprints:      in.ManagedFingerprints,
		ControlPlaneFingerprints: control,
	})
}
