package store

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/model"
)

func ConfigDir() (string, error) {
	if v := os.Getenv("SKM2_CONFIG_DIR"); v != "" {
		return v, nil
	}
	d, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(d, "skm", "v2"), nil
}

func StatePath() (string, error) {
	d, err := ConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(d, "state.json"), nil
}
func HistoryPath() (string, error) {
	d, err := ConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(d, "history.jsonl"), nil
}

func NewID(prefix string) string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return fmt.Sprintf("%s_%s", prefix, hex.EncodeToString(b))
}

func Revision(v any) string {
	b, _ := json.Marshal(v)
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

func Save(f *model.Fleet) error {
	p, err := StatePath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(p), 0700); err != nil {
		return err
	}
	f.Schema = 2
	f.UpdatedAt = time.Now().UTC()
	f.Revision = ""
	f.Revision = Revision(f)
	b, err := json.MarshalIndent(f, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(p), ".state-*.json")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if err := tmp.Chmod(0600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(append(b, '\n')); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(name, p)
}

func Load() (*model.Fleet, error) {
	p, err := StatePath()
	if err != nil {
		return nil, err
	}
	b, err := os.ReadFile(p)
	if errors.Is(err, os.ErrNotExist) {
		return nil, os.ErrNotExist
	}
	if err != nil {
		return nil, err
	}
	var f model.Fleet
	if err := json.Unmarshal(b, &f); err != nil {
		return nil, err
	}
	if f.Schema != 2 {
		return nil, fmt.Errorf("unsupported state schema %d", f.Schema)
	}
	return &f, nil
}

func Init(name string) (*model.Fleet, error) {
	if name == "" {
		name = "Default Fleet"
	}
	f := &model.Fleet{Schema: 2, FleetID: NewID("fleet"), Name: name}
	if err := Save(f); err != nil {
		return nil, err
	}
	return f, nil
}

func AppendHistory(event any) error {
	p, err := HistoryPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(p), 0700); err != nil {
		return err
	}
	b, err := json.Marshal(event)
	if err != nil {
		return err
	}
	fh, err := os.OpenFile(p, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer fh.Close()
	_, err = fh.Write(append(b, '\n'))
	return err
}

func Backup(dst string, f *model.Fleet) error {
	if dst == "" {
		return errors.New("backup destination required")
	}
	b, err := json.MarshalIndent(struct {
		Format string       `json:"format"`
		Fleet  *model.Fleet `json:"fleet"`
	}{"SKM2-BACKUP-1", f}, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(dst, append(b, '\n'), 0600)
}

func Restore(src string) (*model.Fleet, error) {
	b, err := os.ReadFile(src)
	if err != nil {
		return nil, err
	}
	var envelope struct {
		Format string       `json:"format"`
		Fleet  *model.Fleet `json:"fleet"`
	}
	if err := json.Unmarshal(b, &envelope); err != nil {
		return nil, err
	}
	if envelope.Format != "SKM2-BACKUP-1" || envelope.Fleet == nil {
		return nil, errors.New("invalid SKM V2 backup")
	}
	if envelope.Fleet.Schema != 2 {
		return nil, fmt.Errorf("unsupported backup schema %d", envelope.Fleet.Schema)
	}
	if err := Save(envelope.Fleet); err != nil {
		return nil, err
	}
	return envelope.Fleet, nil
}
