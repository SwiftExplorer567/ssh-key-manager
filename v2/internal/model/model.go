package model

import "time"

type PolicyMode string

const (
	PolicyObserve       PolicyMode = "observe"
	PolicyAdditive      PolicyMode = "additive"
	PolicyAuthoritative PolicyMode = "authoritative"
)

type CredentialStatus string

const (
	CredentialActive   CredentialStatus = "active"
	CredentialRetiring CredentialStatus = "retiring"
	CredentialRetired  CredentialStatus = "retired"
)

type Fleet struct {
	Schema      int          `json:"schema"`
	FleetID     string       `json:"fleet_id"`
	Name        string       `json:"name"`
	Revision    string       `json:"revision"`
	UpdatedAt   time.Time    `json:"updated_at"`
	Subjects    []Subject    `json:"subjects"`
	Credentials []Credential `json:"credentials"`
	Nodes       []Node       `json:"nodes"`
	Policies    []Policy     `json:"policies"`
	Groups      []Group      `json:"groups,omitempty"`
}

type Subject struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Type   string `json:"type"`
	Status string `json:"status"`
}

type Credential struct {
	ID          string           `json:"id"`
	SubjectID   string           `json:"subject_id"`
	Fingerprint string           `json:"fingerprint"`
	Algorithm   string           `json:"algorithm,omitempty"`
	Status      CredentialStatus `json:"status"`
	PublicKey   string           `json:"public_key,omitempty"`
}

type Node struct {
	ID         string      `json:"id"`
	Name       string      `json:"name"`
	Principals []Principal `json:"principals"`
	HostTrust  HostTrust   `json:"host_trust,omitempty"`
}

type Principal struct {
	ID         string     `json:"id"`
	Username   string     `json:"username"`
	PolicyMode PolicyMode `json:"policy_mode"`
	Routes     []Route    `json:"routes"`
}

type Route struct {
	ID             string `json:"id"`
	Type           string `json:"type"`
	Host           string `json:"host,omitempty"`
	Port           int    `json:"port,omitempty"`
	SSHConfigAlias string `json:"ssh_config_alias,omitempty"`
	ProxyJump      string `json:"proxy_jump,omitempty"`
	Priority       int    `json:"priority"`
}

type HostTrust struct {
	Method       string     `json:"method,omitempty"`
	Keys         []HostKey  `json:"keys,omitempty"`
	VerifiedAt   *time.Time `json:"verified_at,omitempty"`
}

type HostKey struct {
	Algorithm   string `json:"algorithm"`
	PublicKey   string `json:"public_key"`
	Fingerprint string `json:"fingerprint,omitempty"`
}

type Policy struct {
	SubjectID   string `json:"subject_id"`
	PrincipalID string `json:"principal_id"`
}

type Group struct {
	ID      string   `json:"id"`
	Name    string   `json:"name"`
	Kind    string   `json:"kind"`
	Members []string `json:"members"`
}

type Grant struct {
	SubjectID    string `json:"subject_id"`
	CredentialID string `json:"credential_id"`
	Fingerprint  string `json:"fingerprint"`
	Managed      bool   `json:"managed"`
}

type ObservedPrincipal struct {
	PrincipalID string  `json:"principal_id"`
	Revision    string  `json:"revision"`
	Grants      []Grant `json:"grants"`
}

type Change struct {
	Action       string `json:"action"`
	PrincipalID  string `json:"principal_id"`
	SubjectID    string `json:"subject_id,omitempty"`
	CredentialID string `json:"credential_id,omitempty"`
	Fingerprint  string `json:"fingerprint"`
	Reason       string `json:"reason"`
}

type Plan struct {
	ID                string            `json:"id"`
	FleetRevision     string            `json:"fleet_revision"`
	CreatedAt         time.Time         `json:"created_at"`
	ExpectedRevisions map[string]string `json:"expected_revisions"`
	Changes           []Change          `json:"changes"`
	Warnings          []string          `json:"warnings,omitempty"`
}
