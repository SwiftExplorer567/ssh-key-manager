package main

import (
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/model"
	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/remote"
	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/store"
)

type credentialRotationResult struct {
	NewCredential model.Credential   `json:"new_credential"`
	Retiring      []model.Credential `json:"retiring"`
}

func parsePublicCredential(path string) (algorithm, publicKey, fingerprint string, err error) {
	info, err := os.Lstat(path)
	if err != nil {
		return "", "", "", err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return "", "", "", fmt.Errorf("public key must be a regular non-symlink file: %s", path)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return "", "", "", err
	}
	fields := strings.Fields(string(b))
	if len(fields) < 2 {
		return "", "", "", errors.New("invalid OpenSSH public key")
	}
	algorithm = fields[0]
	publicKey = fields[0] + " " + fields[1]
	fingerprint, err = remote.FingerprintPublic(publicKey)
	return algorithm, publicKey, fingerprint, err
}

func findSubjectCredentialIndex(f *model.Fleet, subjectName, selector string) (int, int, error) {
	si, err := findSubjectIndex(f, subjectName)
	if err != nil {
		return -1, -1, err
	}
	selector = strings.TrimSpace(selector)
	for i := range f.Credentials {
		c := f.Credentials[i]
		if c.SubjectID != f.Subjects[si].ID {
			continue
		}
		if c.ID == selector || c.Fingerprint == selector {
			return si, i, nil
		}
	}
	return -1, -1, fmt.Errorf("credential not found for subject %s: %s", subjectName, selector)
}

func rotateCredential(f *model.Fleet, subjectName, pubPath string) (*credentialRotationResult, error) {
	si, err := findSubjectIndex(f, subjectName)
	if err != nil {
		return nil, err
	}
	algorithm, publicKey, fp, err := parsePublicCredential(pubPath)
	if err != nil {
		return nil, err
	}

	for _, c := range f.Credentials {
		if c.Fingerprint == fp && c.SubjectID != f.Subjects[si].ID {
			return nil, fmt.Errorf("credential %s already belongs to another subject", fp)
		}
	}

	newIndex := -1
	retiring := []model.Credential{}
	for i := range f.Credentials {
		c := &f.Credentials[i]
		if c.SubjectID != f.Subjects[si].ID {
			continue
		}
		if c.Fingerprint == fp {
			newIndex = i
			continue
		}
		if c.Status == model.CredentialActive {
			c.Status = model.CredentialRetiring
			retiring = append(retiring, *c)
		}
	}

	if newIndex >= 0 {
		c := &f.Credentials[newIndex]
		c.Algorithm = algorithm
		c.PublicKey = publicKey
		c.Status = model.CredentialActive
	} else {
		f.Credentials = append(f.Credentials, model.Credential{
			ID:          store.NewID("cred"),
			SubjectID:   f.Subjects[si].ID,
			Fingerprint: fp,
			Algorithm:   algorithm,
			Status:      model.CredentialActive,
			PublicKey:   publicKey,
		})
		newIndex = len(f.Credentials) - 1
	}

	if err := store.Save(f); err != nil {
		return nil, err
	}
	return &credentialRotationResult{NewCredential: f.Credentials[newIndex], Retiring: retiring}, nil
}

func setCredentialLifecycleStatus(f *model.Fleet, subjectName, selector string, status model.CredentialStatus) (*model.Credential, error) {
	si, ci, err := findSubjectCredentialIndex(f, subjectName, selector)
	if err != nil {
		return nil, err
	}
	if status != model.CredentialActive && status != model.CredentialRetiring && status != model.CredentialRetired {
		return nil, fmt.Errorf("invalid credential status: %s", status)
	}

	if status == model.CredentialRetired {
		policyUsesSubject := false
		for _, p := range f.Policies {
			if p.SubjectID == f.Subjects[si].ID {
				policyUsesSubject = true
				break
			}
		}
		if policyUsesSubject {
			hasOtherActive := false
			for i, c := range f.Credentials {
				if i == ci || c.SubjectID != f.Subjects[si].ID {
					continue
				}
				if c.Status == model.CredentialActive {
					hasOtherActive = true
					break
				}
			}
			if !hasOtherActive {
				return nil, errors.New("refusing to retire the last active credential for a subject referenced by policy")
			}
		}
	}

	f.Credentials[ci].Status = status
	if err := store.Save(f); err != nil {
		return nil, err
	}
	return &f.Credentials[ci], nil
}
