package remote

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/bridge"
	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/model"
	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/store"
)

const bridgeVersion = "SKM2-BRIDGE|2"

type target struct {
	NodeIndex      int
	PrincipalIndex int
	Node           model.Node
	Principal      model.Principal
	Route          model.Route
}

type parsedEntry struct {
	Line        string
	Fingerprint string
	PublicKey   string
	Algorithm   string
}

type Inspection struct {
	NodeName            string                  `json:"node_name"`
	Username            string                  `json:"username"`
	Observed            model.ObservedPrincipal `json:"observed"`
	ManagedFingerprints []string                `json:"managed_fingerprints"`
	Lines               []string                `json:"-"`
	entries             []parsedEntry
}

type EnrollmentResult struct {
	Node                  string `json:"node"`
	Username              string `json:"username"`
	ManagedKeyPath        string `json:"managed_key_path"`
	ManagedKeyFingerprint string `json:"managed_key_fingerprint"`
	BridgeVersion         string `json:"bridge_version"`
}

type UnenrollmentResult struct {
	Node       string `json:"node"`
	Username   string `json:"username"`
	KeyRemoved bool   `json:"key_removed"`
}

type ApplyResult struct {
	PrincipalID string `json:"principal_id"`
	Node        string `json:"node"`
	Username    string `json:"username"`
	OldRevision string `json:"old_revision"`
	NewRevision string `json:"new_revision"`
}

func homeFile(envName, fallback string) (string, error) {
	if v := os.Getenv(envName); v != "" {
		return v, nil
	}
	h, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(h, fallback), nil
}

func ManagedKeyPath() (string, error) {
	return homeFile("SKM2_MANAGED_KEY", filepath.Join(".ssh", "id_ed25519_skm2"))
}

func BootstrapKeyPath() (string, error) {
	return homeFile("SKM2_BOOTSTRAP_KEY", filepath.Join(".ssh", "id_ed25519_skm"))
}

func requireRegularNonSymlink(path, label string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return fmt.Errorf("%s must be a regular non-symlink file: %s", label, path)
	}
	return nil
}

func loadManagedPublic(path string) (string, string, error) {
	if err := requireRegularNonSymlink(path, "managed private key"); err != nil {
		return "", "", err
	}
	pubPath := path + ".pub"
	var pub []byte
	if err := requireRegularNonSymlink(pubPath, "managed public key"); err == nil {
		var readErr error
		pub, readErr = os.ReadFile(pubPath)
		if readErr != nil {
			return "", "", readErr
		}
	} else if errors.Is(err, os.ErrNotExist) {
		cmd := exec.Command("ssh-keygen", "-y", "-f", path)
		out, runErr := cmd.Output()
		if runErr != nil {
			return "", "", fmt.Errorf("derive managed public key: %w", runErr)
		}
		pub = append(bytes.TrimSpace(out), []byte(" skm2-controller\n")...)
	} else {
		return "", "", err
	}
	pubLine := strings.TrimSpace(string(pub))
	fp, err := FingerprintPublic(pubLine)
	if err != nil {
		return "", "", err
	}
	return pubLine, fp, nil
}

func EnsureManagedKey() (string, string, string, error) {
	path, err := ManagedKeyPath()
	if err != nil {
		return "", "", "", err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return "", "", "", err
	}
	_ = os.Chmod(filepath.Dir(path), 0700)

	if err := requireRegularNonSymlink(path, "managed private key"); errors.Is(err, os.ErrNotExist) {
		cmd := exec.Command("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "skm2-controller", "-f", path)
		if out, runErr := cmd.CombinedOutput(); runErr != nil {
			return "", "", "", fmt.Errorf("generate managed key: %w: %s", runErr, strings.TrimSpace(string(out)))
		}
	} else if err != nil {
		return "", "", "", err
	}
	_ = os.Chmod(path, 0600)

	pubLine, fp, err := loadManagedPublic(path)
	if err != nil {
		return "", "", "", err
	}
	pubPath := path + ".pub"
	if _, err := os.Stat(pubPath); errors.Is(err, os.ErrNotExist) {
		if err := os.WriteFile(pubPath, []byte(pubLine+"\n"), 0644); err != nil {
			return "", "", "", err
		}
	}
	return path, pubLine, fp, nil
}

func resolveSSHConfigRoute(r model.Route) (model.Route, error) {
	alias := strings.TrimSpace(r.SSHConfigAlias)
	if alias == "" {
		return model.Route{}, errors.New("ssh-config route requires ssh_config_alias")
	}
	cmd := exec.Command("ssh", "-G", alias)
	out, err := cmd.Output()
	if err != nil {
		return model.Route{}, fmt.Errorf("resolve ssh config alias %s: %w", alias, err)
	}
	host := ""
	port := 0
	configProxyJump := ""
	for _, line := range strings.Split(strings.ReplaceAll(string(out), "\r\n", "\n"), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		switch strings.ToLower(fields[0]) {
		case "hostname":
			host = fields[1]
		case "port":
			if v, convErr := strconv.Atoi(fields[1]); convErr == nil {
				port = v
			}
		case "proxyjump":
			if fields[1] != "none" {
				configProxyJump = fields[1]
			}
		}
	}
	if host == "" {
		return model.Route{}, fmt.Errorf("ssh config alias %s resolved without a hostname", alias)
	}
	if r.Port == 0 {
		if port == 0 {
			port = 22
		}
		r.Port = port
	}
	if r.ProxyJump == "" {
		r.ProxyJump = configProxyJump
	}
	r.Host = host
	return r, nil
}

func normalizeRoute(r model.Route) (model.Route, error) {
	switch r.Type {
	case "direct", "tailscale":
		if strings.TrimSpace(r.Host) == "" || r.Host == "local" {
			return model.Route{}, errors.New("remote route requires a non-local host")
		}
		if r.Port == 0 {
			r.Port = 22
		}
		return r, nil
	case "ssh-config":
		return resolveSSHConfigRoute(r)
	default:
		return model.Route{}, fmt.Errorf("unsupported route type %q", r.Type)
	}
}

func resolveTarget(f *model.Fleet, nodeName, user string) (target, error) {
	for ni := range f.Nodes {
		n := f.Nodes[ni]
		if n.Name != nodeName {
			continue
		}
		pi := -1
		if user == "" {
			if len(n.Principals) != 1 {
				return target{}, fmt.Errorf("node %s has %d principals; specify --user", nodeName, len(n.Principals))
			}
			pi = 0
		} else {
			for i := range n.Principals {
				if n.Principals[i].Username == user {
					pi = i
					break
				}
			}
			if pi < 0 {
				return target{}, fmt.Errorf("principal %s not found on node %s", user, nodeName)
			}
		}
		pr := n.Principals[pi]
		routes := append([]model.Route(nil), pr.Routes...)
		sort.SliceStable(routes, func(i, j int) bool { return routes[i].Priority < routes[j].Priority })
		routeErrors := []string{}
		for _, r := range routes {
			normalized, err := normalizeRoute(r)
			if err != nil {
				routeErrors = append(routeErrors, fmt.Sprintf("%s: %v", r.ID, err))
				continue
			}
			return target{NodeIndex: ni, PrincipalIndex: pi, Node: n, Principal: pr, Route: normalized}, nil
		}
		if len(routeErrors) == 0 {
			return target{}, fmt.Errorf("node %s/%s has no remote routes", nodeName, pr.Username)
		}
		return target{}, fmt.Errorf("node %s/%s has no usable route: %s", nodeName, pr.Username, strings.Join(routeErrors, "; "))
	}
	return target{}, fmt.Errorf("node not found: %s", nodeName)
}

func resolvePrincipalID(f *model.Fleet, principalID string) (target, error) {
	for ni := range f.Nodes {
		for pi := range f.Nodes[ni].Principals {
			if f.Nodes[ni].Principals[pi].ID == principalID {
				return resolveTarget(f, f.Nodes[ni].Name, f.Nodes[ni].Principals[pi].Username)
			}
		}
	}
	return target{}, fmt.Errorf("principal id not found: %s", principalID)
}

func knownHostsToken(r model.Route) string {
	if r.Port == 22 || r.Port == 0 {
		return r.Host
	}
	return fmt.Sprintf("[%s]:%d", r.Host, r.Port)
}

func writeKnownHosts(t target) (string, func(), error) {
	if len(t.Node.HostTrust.Keys) == 0 {
		return "", func() {}, fmt.Errorf("node %s has no pinned host key; enrollment and bridge access fail closed", t.Node.Name)
	}
	fh, err := os.CreateTemp("", "skm2-known-hosts-*")
	if err != nil {
		return "", func() {}, err
	}
	cleanup := func() { _ = os.Remove(fh.Name()) }
	if err := fh.Chmod(0600); err != nil {
		_ = fh.Close()
		cleanup()
		return "", func() {}, err
	}
	token := knownHostsToken(t.Route)
	written := 0
	for _, k := range t.Node.HostTrust.Keys {
		if k.Algorithm == "" || k.PublicKey == "" {
			continue
		}
		if _, err := fmt.Fprintf(fh, "%s %s %s\n", token, k.Algorithm, k.PublicKey); err != nil {
			_ = fh.Close()
			cleanup()
			return "", func() {}, err
		}
		written++
	}
	if err := fh.Close(); err != nil {
		cleanup()
		return "", func() {}, err
	}
	if written == 0 {
		cleanup()
		return "", func() {}, fmt.Errorf("node %s has no usable pinned host keys", t.Node.Name)
	}
	return fh.Name(), cleanup, nil
}

func runSSH(t target, key string, batch bool, stdin []byte, remoteArgs ...string) (string, string, error) {
	kh, cleanup, err := writeKnownHosts(t)
	if err != nil {
		return "", "", err
	}
	defer cleanup()

	args := []string{
		"-T",
		"-o", "StrictHostKeyChecking=yes",
		"-o", "UserKnownHostsFile=" + kh,
		"-o", "GlobalKnownHostsFile=/dev/null",
		"-o", "ConnectTimeout=7",
	}
	if key != "" {
		args = append(args, "-i", key, "-o", "IdentitiesOnly=yes")
	}
	if batch {
		args = append(args, "-o", "BatchMode=yes")
	}
	if t.Route.ProxyJump != "" {
		args = append(args, "-J", t.Route.ProxyJump)
	}
	if t.Route.Port != 22 {
		args = append(args, "-p", strconv.Itoa(t.Route.Port))
	}
	destinationHost := t.Route.Host
	if t.Route.Type == "ssh-config" && t.Route.SSHConfigAlias != "" {
		destinationHost = t.Route.SSHConfigAlias
	}
	args = append(args, t.Principal.Username+"@"+destinationHost)
	args = append(args, remoteArgs...)

	cmd := exec.Command("ssh", args...)
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return stdout.String(), stderr.String(), fmt.Errorf("ssh %s@%s via %s: %w: %s", t.Principal.Username, destinationHost, t.Route.Type, err, strings.TrimSpace(stderr.String()))
	}
	return stdout.String(), stderr.String(), nil
}

func shellQuote(v string) string {
	return "'" + strings.ReplaceAll(v, "'", "'\"'\"'") + "'"
}

func enrollmentScript(pubLine string) (string, error) {
	fields := strings.Fields(pubLine)
	if len(fields) < 2 {
		return "", errors.New("invalid controller public key")
	}
	blob := fields[1]
	forcedLine := `restrict,command="$HOME/.local/libexec/skm2/bridge" ` + pubLine
	return fmt.Sprintf(`set -eu
umask 077
mkdir -p "$HOME/.ssh" "$HOME/.local/libexec/skm2"
chmod 700 "$HOME/.ssh" "$HOME/.local/libexec/skm2" 2>/dev/null || true
bridge="$HOME/.local/libexec/skm2/bridge"
ak="$HOME/.ssh/authorized_keys"
cat > "$bridge" <<'SKM2_BRIDGE_EOF'
%sSKM2_BRIDGE_EOF
chmod 700 "$bridge"
[ ! -L "$ak" ] || { echo 'symlinked authorized_keys refused' >&2; exit 20; }
[ -e "$ak" ] || : > "$ak"
chmod 600 "$ak"
cp -p "$ak" "${ak}.skm2-enroll.bak"
tmp="${ak}.skm2-enroll.$$"
trap 'rm -f "$tmp"' EXIT HUP INT TERM
blob=%s
awk -v blob="$blob" 'index($0, blob) == 0 { print }' "$ak" > "$tmp"
printf '%%s\n' %s >> "$tmp"
chmod 600 "$tmp"
mv -f "$tmp" "$ak"
trap - EXIT HUP INT TERM
`, bridge.Script, shellQuote(blob), shellQuote(forcedLine)), nil
}

func unenrollmentScript(pubLine string) (string, error) {
	fields := strings.Fields(pubLine)
	if len(fields) < 2 {
		return "", errors.New("invalid controller public key")
	}
	blob := fields[1]
	return fmt.Sprintf(`set -eu
umask 077
ak="$HOME/.ssh/authorized_keys"
[ ! -L "$ak" ] || { echo 'symlinked authorized_keys refused' >&2; exit 20; }
[ -f "$ak" ] || exit 0
cp -p "$ak" "${ak}.skm2-unenroll.bak"
tmp="${ak}.skm2-unenroll.$$"
trap 'rm -f "$tmp"' EXIT HUP INT TERM
blob=%s
awk -v blob="$blob" 'index($0, blob) == 0 { print }' "$ak" > "$tmp"
chmod 600 "$tmp"
mv -f "$tmp" "$ak"
trap - EXIT HUP INT TERM
`, shellQuote(blob)), nil
}

func bootstrapKeyOrDefault(path string) (string, error) {
	if path == "" {
		var err error
		path, err = BootstrapKeyPath()
		if err != nil {
			return "", err
		}
	}
	if err := requireRegularNonSymlink(path, "bootstrap key"); err != nil {
		return "", fmt.Errorf("bootstrap key unavailable: %s: %w", path, err)
	}
	return path, nil
}

func Enroll(f *model.Fleet, nodeName, user, bootstrapKey string) (EnrollmentResult, error) {
	t, err := resolveTarget(f, nodeName, user)
	if err != nil {
		return EnrollmentResult{}, err
	}
	managedKey, pubLine, fp, err := EnsureManagedKey()
	if err != nil {
		return EnrollmentResult{}, err
	}
	bootstrapKey, err = bootstrapKeyOrDefault(bootstrapKey)
	if err != nil {
		return EnrollmentResult{}, err
	}
	script, err := enrollmentScript(pubLine)
	if err != nil {
		return EnrollmentResult{}, err
	}
	if _, _, err := runSSH(t, bootstrapKey, true, []byte(script), "sh", "-s"); err != nil {
		return EnrollmentResult{}, fmt.Errorf("enroll restricted bridge: %w", err)
	}
	v, err := BridgeVersion(f, nodeName, t.Principal.Username)
	if err != nil {
		return EnrollmentResult{}, fmt.Errorf("bridge installed but restricted verification failed: %w", err)
	}
	return EnrollmentResult{
		Node:                  nodeName,
		Username:              t.Principal.Username,
		ManagedKeyPath:        managedKey,
		ManagedKeyFingerprint: fp,
		BridgeVersion:         v,
	}, nil
}

func Unenroll(f *model.Fleet, nodeName, user, bootstrapKey string) (UnenrollmentResult, error) {
	t, err := resolveTarget(f, nodeName, user)
	if err != nil {
		return UnenrollmentResult{}, err
	}
	managedKey, err := ManagedKeyPath()
	if err != nil {
		return UnenrollmentResult{}, err
	}
	pubLine, _, err := loadManagedPublic(managedKey)
	if err != nil {
		return UnenrollmentResult{}, err
	}
	bootstrapKey, err = bootstrapKeyOrDefault(bootstrapKey)
	if err != nil {
		return UnenrollmentResult{}, err
	}
	script, err := unenrollmentScript(pubLine)
	if err != nil {
		return UnenrollmentResult{}, err
	}
	if _, _, err := runSSH(t, bootstrapKey, true, []byte(script), "sh", "-s"); err != nil {
		return UnenrollmentResult{}, fmt.Errorf("remove restricted management key: %w", err)
	}
	return UnenrollmentResult{Node: nodeName, Username: t.Principal.Username, KeyRemoved: true}, nil
}

func BridgeVersion(f *model.Fleet, nodeName, user string) (string, error) {
	t, err := resolveTarget(f, nodeName, user)
	if err != nil {
		return "", err
	}
	key, err := ManagedKeyPath()
	if err != nil {
		return "", err
	}
	if err := requireRegularNonSymlink(key, "managed key"); err != nil {
		return "", err
	}
	out, _, err := runSSH(t, key, true, nil, "version")
	if err != nil {
		return "", err
	}
	v := strings.TrimSpace(out)
	if v != bridgeVersion {
		return "", fmt.Errorf("unsupported bridge version %q", v)
	}
	return v, nil
}

func FingerprintPublic(publicLine string) (string, error) {
	cmd := exec.Command("ssh-keygen", "-E", "sha256", "-lf", "/dev/stdin")
	cmd.Stdin = strings.NewReader(strings.TrimSpace(publicLine) + "\n")
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("fingerprint public key: %w", err)
	}
	fields := strings.Fields(string(out))
	if len(fields) < 2 || !strings.HasPrefix(fields[1], "SHA256:") {
		return "", errors.New("unexpected ssh-keygen fingerprint output")
	}
	return fields[1], nil
}

func keyType(v string) bool {
	return strings.HasPrefix(v, "ssh-") || strings.HasPrefix(v, "ecdsa-") || strings.HasPrefix(v, "sk-")
}

func parseAuthorizedLine(line string) (parsedEntry, bool, error) {
	trimmed := strings.TrimSpace(line)
	if trimmed == "" || strings.HasPrefix(trimmed, "#") {
		return parsedEntry{Line: line}, false, nil
	}
	fields := strings.Fields(trimmed)
	for i := 0; i+1 < len(fields); i++ {
		if !keyType(fields[i]) {
			continue
		}
		pub := fields[i] + " " + fields[i+1]
		fp, err := FingerprintPublic(pub)
		if err != nil {
			continue
		}
		return parsedEntry{Line: line, Fingerprint: fp, PublicKey: pub, Algorithm: fields[i]}, true, nil
	}
	return parsedEntry{Line: line}, false, nil
}

func parseInspection(f *model.Fleet, t target, raw string) (Inspection, bool, error) {
	lines := strings.Split(strings.ReplaceAll(raw, "\r\n", "\n"), "\n")
	if len(lines) < 3 || lines[0] != "SKM2-STATE|2" {
		return Inspection{}, false, errors.New("invalid bridge inspect response")
	}
	revision := ""
	managed := map[string]bool{}
	separator := -1
	for i := 1; i < len(lines); i++ {
		if lines[i] == "--" {
			separator = i
			break
		}
		if strings.HasPrefix(lines[i], "revision=") {
			revision = strings.TrimPrefix(lines[i], "revision=")
		} else if strings.HasPrefix(lines[i], "managed=SHA256:") {
			fp := strings.TrimPrefix(lines[i], "managed=")
			managed[fp] = true
		}
	}
	if revision == "" || separator < 0 {
		return Inspection{}, false, errors.New("incomplete bridge inspect response")
	}

	body := append([]string(nil), lines[separator+1:]...)
	if len(body) > 0 && body[len(body)-1] == "" {
		body = body[:len(body)-1]
	}

	credByFP := map[string]int{}
	for i := range f.Credentials {
		credByFP[f.Credentials[i].Fingerprint] = i
	}
	grants := []model.Grant{}
	entries := make([]parsedEntry, 0, len(body))
	present := map[string]bool{}
	enriched := false
	for _, line := range body {
		entry, isKey, err := parseAuthorizedLine(line)
		if err != nil {
			return Inspection{}, false, fmt.Errorf("parse authorized_keys line: %w", err)
		}
		entries = append(entries, entry)
		if !isKey {
			continue
		}
		present[entry.Fingerprint] = true
		g := model.Grant{Fingerprint: entry.Fingerprint, Managed: managed[entry.Fingerprint]}
		if idx, ok := credByFP[entry.Fingerprint]; ok {
			g.CredentialID = f.Credentials[idx].ID
			g.SubjectID = f.Credentials[idx].SubjectID
			if f.Credentials[idx].PublicKey == "" {
				f.Credentials[idx].PublicKey = entry.PublicKey
				f.Credentials[idx].Algorithm = entry.Algorithm
				enriched = true
			}
		}
		grants = append(grants, g)
	}

	managedList := []string{}
	for fp := range managed {
		if present[fp] {
			managedList = append(managedList, fp)
		}
	}
	sort.Strings(managedList)

	return Inspection{
		NodeName:            t.Node.Name,
		Username:            t.Principal.Username,
		Observed:            model.ObservedPrincipal{PrincipalID: t.Principal.ID, Revision: revision, Grants: grants},
		ManagedFingerprints: managedList,
		Lines:               body,
		entries:             entries,
	}, enriched, nil
}

func Inspect(f *model.Fleet, nodeName, user string) (Inspection, bool, error) {
	t, err := resolveTarget(f, nodeName, user)
	if err != nil {
		return Inspection{}, false, err
	}
	key, err := ManagedKeyPath()
	if err != nil {
		return Inspection{}, false, err
	}
	if err := requireRegularNonSymlink(key, "managed key"); err != nil {
		return Inspection{}, false, err
	}
	out, _, err := runSSH(t, key, true, nil, "inspect")
	if err != nil {
		return Inspection{}, false, err
	}
	return parseInspection(f, t, out)
}

func credentialByChange(f *model.Fleet, c model.Change) (*model.Credential, error) {
	for i := range f.Credentials {
		if (c.CredentialID != "" && f.Credentials[i].ID == c.CredentialID) || f.Credentials[i].Fingerprint == c.Fingerprint {
			return &f.Credentials[i], nil
		}
	}
	return nil, fmt.Errorf("credential not found for %s", c.Fingerprint)
}

func renderChanges(f *model.Fleet, in Inspection, changes []model.Change) ([]byte, []string, error) {
	lines := append([]string(nil), in.Lines...)
	managed := map[string]bool{}
	for _, fp := range in.ManagedFingerprints {
		managed[fp] = true
	}

	for _, c := range changes {
		switch c.Action {
		case "grant":
			exists := false
			for _, e := range in.entries {
				if e.Fingerprint == c.Fingerprint {
					exists = true
					break
				}
			}
			if exists {
				continue
			}
			cred, err := credentialByChange(f, c)
			if err != nil {
				return nil, nil, err
			}
			if strings.TrimSpace(cred.PublicKey) == "" {
				return nil, nil, fmt.Errorf("credential %s has no public key material; inspect a node containing it or import its .pub file first", cred.ID)
			}
			lines = append(lines, strings.TrimSpace(cred.PublicKey)+" skm2:"+cred.ID)
			managed[c.Fingerprint] = true

		case "revoke":
			if !managed[c.Fingerprint] {
				return nil, nil, fmt.Errorf("refusing to revoke unmanaged credential %s", c.Fingerprint)
			}
			kept := make([]string, 0, len(lines))
			removed := false
			for _, line := range lines {
				e, isKey, err := parseAuthorizedLine(line)
				if err != nil {
					return nil, nil, err
				}
				if isKey && e.Fingerprint == c.Fingerprint {
					removed = true
					continue
				}
				kept = append(kept, line)
			}
			if !removed {
				return nil, nil, fmt.Errorf("managed credential %s disappeared before apply", c.Fingerprint)
			}
			lines = kept
			delete(managed, c.Fingerprint)

		default:
			return nil, nil, fmt.Errorf("unsupported plan action %q", c.Action)
		}
	}

	present := map[string]bool{}
	for _, line := range lines {
		e, isKey, err := parseAuthorizedLine(line)
		if err != nil {
			return nil, nil, err
		}
		if isKey {
			present[e.Fingerprint] = true
		}
	}
	managedList := []string{}
	for fp := range managed {
		if present[fp] {
			managedList = append(managedList, fp)
		}
	}
	sort.Strings(managedList)

	content := strings.Join(lines, "\n")
	if len(lines) > 0 {
		content += "\n"
	}
	return []byte(content), managedList, nil
}

func parseApplied(raw string) (string, error) {
	lines := strings.Split(strings.ReplaceAll(raw, "\r\n", "\n"), "\n")
	if len(lines) < 2 || lines[0] != "SKM2-APPLIED|2" {
		return "", errors.New("invalid bridge apply response")
	}
	for _, line := range lines[1:] {
		if strings.HasPrefix(line, "revision=") {
			v := strings.TrimPrefix(line, "revision=")
			if v != "" {
				return v, nil
			}
		}
	}
	return "", errors.New("bridge apply response missing revision")
}

type stagedApply struct {
	target   target
	expected string
	content  []byte
	managed  []string
}

func ApplyPlan(f *model.Fleet, p model.Plan) ([]ApplyResult, error) {
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

	// Preflight every target before the first mutation. This catches stale remote
	// state, missing public key material and unsupported targets before a fleet
	// operation can become partially applied.
	staged := make([]stagedApply, 0, len(principalIDs))
	for _, pid := range principalIDs {
		t, err := resolvePrincipalID(f, pid)
		if err != nil {
			return nil, err
		}
		out, _, err := runSSH(t, key, true, nil, "inspect")
		if err != nil {
			return nil, err
		}
		inspection, _, err := parseInspection(f, t, out)
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
	for _, s := range staged {
		args := []string{"apply", s.expected}
		args = append(args, s.managed...)
		appliedOut, _, err := runSSH(s.target, key, true, s.content, args...)
		if err != nil {
			return results, err
		}
		newRevision, err := parseApplied(appliedOut)
		if err != nil {
			return results, err
		}
		r := ApplyResult{
			PrincipalID: s.target.Principal.ID,
			Node:        s.target.Node.Name,
			Username:    s.target.Principal.Username,
			OldRevision: s.expected,
			NewRevision: newRevision,
		}
		results = append(results, r)
		_ = store.AppendHistory(map[string]any{
			"time":          time.Now().UTC(),
			"operation":     "apply",
			"plan_id":       p.ID,
			"principal_id":  s.target.Principal.ID,
			"node":          s.target.Node.Name,
			"username":      s.target.Principal.Username,
			"old_revision":  s.expected,
			"new_revision":  newRevision,
		})
	}
	return results, nil
}

func Rollback(f *model.Fleet, nodeName, user, expected string) (ApplyResult, error) {
	if expected == "" {
		return ApplyResult{}, errors.New("expected current revision is required")
	}
	t, err := resolveTarget(f, nodeName, user)
	if err != nil {
		return ApplyResult{}, err
	}
	key, err := ManagedKeyPath()
	if err != nil {
		return ApplyResult{}, err
	}
	if err := requireRegularNonSymlink(key, "managed key"); err != nil {
		return ApplyResult{}, err
	}
	out, _, err := runSSH(t, key, true, nil, "rollback", expected)
	if err != nil {
		return ApplyResult{}, err
	}
	newRevision, err := parseApplied(out)
	if err != nil {
		return ApplyResult{}, err
	}
	r := ApplyResult{
		PrincipalID: t.Principal.ID,
		Node:        t.Node.Name,
		Username:    t.Principal.Username,
		OldRevision: expected,
		NewRevision: newRevision,
	}
	_ = store.AppendHistory(map[string]any{
		"time":          time.Now().UTC(),
		"operation":     "rollback",
		"principal_id":  t.Principal.ID,
		"node":          t.Node.Name,
		"username":      t.Principal.Username,
		"old_revision":  expected,
		"new_revision":  newRevision,
	})
	return r, nil
}
