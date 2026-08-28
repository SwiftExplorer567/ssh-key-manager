package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/bridge"
	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/migrate"
	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/model"
	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/planner"
	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/remote"
	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/store"
)

const version = "2.0.0-beta.1"

func die(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}

func usage() {
	fmt.Print(`SSH Key Manager V2 beta

Usage:
  skm2 version
  skm2 init [NAME]
  skm2 status
  skm2 migrate v1 [V1_CONFIG_DIR] [--save] [--force]

  skm2 node list
  skm2 node enroll NAME [--user USER] [--bootstrap-key FILE] --yes
  skm2 node unenroll NAME [--user USER] [--bootstrap-key FILE] --yes
  skm2 node inspect NAME [--user USER]
  skm2 node bridge-version NAME [--user USER]
  skm2 node rollback NAME [--user USER] --expected REVISION --yes

  skm2 subject list
  skm2 subject add NAME [TYPE]
  skm2 credential list
  skm2 credential import SUBJECT PUBLIC_KEY_FILE

  skm2 policy list
  skm2 policy grant SUBJECT NODE [--user USER]
  skm2 policy revoke SUBJECT NODE [--user USER]
  skm2 policy mode NODE MODE [--user USER]

  skm2 plan --node NAME [--user USER] [--out FILE]
  skm2 plan --observed FILE [--out FILE]
  skm2 apply PLAN_FILE --yes

  skm2 backup create FILE
  skm2 backup restore FILE --yes
  skm2 history
  skm2 bridge print

V2 is local-first. Private keys are never stored in fleet state or backups.
Remote mutation is available only through an enrolled restricted bridge and
requires pinned host trust plus an explicit --yes confirmation.
`)
}

func load() *model.Fleet {
	f, err := store.Load()
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			die(fmt.Errorf("no V2 fleet; run skm2 init or skm2 migrate v1 --save"))
		}
		die(err)
	}
	return f
}

func out(v any) {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		die(err)
	}
	fmt.Println(string(b))
}

func parseArgs(args []string, valueFlags ...string) ([]string, map[string]string, map[string]bool, error) {
	allowed := map[string]bool{}
	for _, f := range valueFlags {
		allowed[f] = true
	}
	pos := []string{}
	values := map[string]string{}
	bools := map[string]bool{}
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--yes" || a == "--save" || a == "--force" {
			bools[a] = true
			continue
		}
		if strings.HasPrefix(a, "--") {
			if !allowed[a] {
				return nil, nil, nil, fmt.Errorf("unknown option %s", a)
			}
			if i+1 >= len(args) {
				return nil, nil, nil, fmt.Errorf("%s requires a value", a)
			}
			i++
			values[a] = args[i]
			continue
		}
		pos = append(pos, a)
	}
	return pos, values, bools, nil
}

func requireYes(b map[string]bool, operation string) {
	if !b["--yes"] {
		die(fmt.Errorf("%s requires --yes", operation))
	}
}

func main() {
	a := os.Args[1:]
	if len(a) == 0 {
		usage()
		return
	}

	switch a[0] {
	case "version":
		fmt.Println(version)

	case "init":
		if _, err := store.Load(); err == nil {
			die(errors.New("V2 fleet already exists; refusing to overwrite it"))
		} else if !errors.Is(err, os.ErrNotExist) {
			die(err)
		}
		name := "Default Fleet"
		if len(a) > 1 {
			name = strings.Join(a[1:], " ")
		}
		f, err := store.Init(name)
		if err != nil {
			die(err)
		}
		out(f)

	case "status":
		f := load()
		fmt.Printf("%s\nrevision %s\n%d nodes · %d subjects · %d credentials · %d policy rules\n", f.Name, f.Revision, len(f.Nodes), len(f.Subjects), len(f.Credentials), len(f.Policies))

	case "migrate":
		if len(a) < 2 || a[1] != "v1" {
			usage()
			os.Exit(2)
		}
		pos, _, flags, err := parseArgs(a[2:])
		if err != nil {
			die(err)
		}
		if len(pos) > 1 {
			die(errors.New("migrate v1 accepts at most one V1_CONFIG_DIR"))
		}
		dir := ""
		if len(pos) == 1 {
			dir = pos[0]
		}
		r, err := migrate.FromV1(dir, "Migrated V1 Fleet")
		if err != nil {
			die(err)
		}
		out(r)
		if flags["--save"] {
			if _, err := store.Load(); err == nil && !flags["--force"] {
				die(errors.New("V2 fleet already exists; rerun migration with --force only after reviewing the preview"))
			} else if err != nil && !errors.Is(err, os.ErrNotExist) {
				die(err)
			}
			if err := store.Save(r.Fleet); err != nil {
				die(err)
			}
			fmt.Fprintln(os.Stderr, "saved V2 state; no remote SSH authorization changed")
		}

	case "node":
		if len(a) < 2 {
			usage()
			os.Exit(2)
		}
		switch a[1] {
		case "list":
			out(load().Nodes)

		case "enroll", "unenroll":
			pos, opts, flags, err := parseArgs(a[2:], "--user", "--bootstrap-key")
			if err != nil {
				die(err)
			}
			if len(pos) != 1 {
				die(fmt.Errorf("node %s requires exactly one node name", a[1]))
			}
			requireYes(flags, "remote enrollment change")
			f := load()
			if a[1] == "enroll" {
				r, err := remote.Enroll(f, pos[0], opts["--user"], opts["--bootstrap-key"])
				if err != nil {
					die(err)
				}
				out(r)
			} else {
				r, err := remote.Unenroll(f, pos[0], opts["--user"], opts["--bootstrap-key"])
				if err != nil {
					die(err)
				}
				out(r)
			}

		case "inspect":
			pos, opts, _, err := parseArgs(a[2:], "--user")
			if err != nil {
				die(err)
			}
			if len(pos) != 1 {
				die(errors.New("node inspect requires exactly one node name"))
			}
			f := load()
			inspection, enriched, err := remote.Inspect(f, pos[0], opts["--user"])
			if err != nil {
				die(err)
			}
			if enriched {
				if err := store.Save(f); err != nil {
					die(err)
				}
				fmt.Fprintln(os.Stderr, "enriched known credential public-key metadata from observed authorization")
			}
			out(inspection)

		case "bridge-version":
			pos, opts, _, err := parseArgs(a[2:], "--user")
			if err != nil {
				die(err)
			}
			if len(pos) != 1 {
				die(errors.New("node bridge-version requires exactly one node name"))
			}
			v, err := remote.BridgeVersion(load(), pos[0], opts["--user"])
			if err != nil {
				die(err)
			}
			fmt.Println(v)

		case "rollback":
			pos, opts, flags, err := parseArgs(a[2:], "--user", "--expected")
			if err != nil {
				die(err)
			}
			if len(pos) != 1 || opts["--expected"] == "" {
				die(errors.New("node rollback requires NODE and --expected REVISION"))
			}
			requireYes(flags, "rollback")
			r, err := remote.Rollback(load(), pos[0], opts["--user"], opts["--expected"])
			if err != nil {
				die(err)
			}
			out(r)

		default:
			usage()
			os.Exit(2)
		}

	case "subject":
		if len(a) < 2 {
			usage(); os.Exit(2)
		}
		switch a[1] {
		case "list":
			out(load().Subjects)
		case "add":
			if len(a) < 3 || len(a) > 4 {
				die(errors.New("subject add requires NAME [TYPE]"))
			}
			kind := "device"
			if len(a) == 4 {
				kind = a[3]
			}
			s, err := addSubject(load(), a[2], kind)
			if err != nil {
				die(err)
			}
			out(s)
		default:
			usage(); os.Exit(2)
		}

	case "credential":
		if len(a) < 2 {
			usage(); os.Exit(2)
		}
		switch a[1] {
		case "list":
			out(load().Credentials)
		case "import":
			if len(a) != 4 {
				die(errors.New("credential import requires SUBJECT PUBLIC_KEY_FILE"))
			}
			c, err := importCredential(load(), a[2], a[3])
			if err != nil {
				die(err)
			}
			out(c)
		default:
			usage(); os.Exit(2)
		}

	case "policy":
		if len(a) < 2 {
			usage(); os.Exit(2)
		}
		switch a[1] {
		case "list":
			out(load().Policies)

		case "grant", "revoke":
			pos, opts, _, err := parseArgs(a[2:], "--user")
			if err != nil {
				die(err)
			}
			if len(pos) != 2 {
				die(fmt.Errorf("policy %s requires SUBJECT NODE", a[1]))
			}
			f := load()
			if a[1] == "grant" {
				p, err := grantPolicy(f, pos[0], pos[1], opts["--user"])
				if err != nil {
					die(err)
				}
				out(p)
			} else {
				if err := revokePolicy(f, pos[0], pos[1], opts["--user"]); err != nil {
					die(err)
				}
				fmt.Println("policy grant removed")
			}

		case "mode":
			pos, opts, _, err := parseArgs(a[2:], "--user")
			if err != nil {
				die(err)
			}
			if len(pos) != 2 {
				die(errors.New("policy mode requires NODE MODE"))
			}
			p, err := setPolicyMode(load(), pos[0], opts["--user"], pos[1])
			if err != nil {
				die(err)
			}
			out(p)

		default:
			usage(); os.Exit(2)
		}

	case "plan":
		pos, opts, _, err := parseArgs(a[1:], "--node", "--user", "--observed", "--out")
		if err != nil {
			die(err)
		}
		if len(pos) != 0 {
			die(fmt.Errorf("unexpected positional plan arguments: %s", strings.Join(pos, " ")))
		}
		if (opts["--node"] == "") == (opts["--observed"] == "") {
			die(errors.New("plan requires exactly one of --node NAME or --observed FILE"))
		}
		f := load()
		var observed []model.ObservedPrincipal
		if opts["--node"] != "" {
			inspection, enriched, err := remote.Inspect(f, opts["--node"], opts["--user"])
			if err != nil {
				die(err)
			}
			if enriched {
				if err := store.Save(f); err != nil {
					die(err)
				}
				fmt.Fprintln(os.Stderr, "enriched credential public-key metadata before planning")
			}
			observed = []model.ObservedPrincipal{inspection.Observed}
		} else {
			b, err := os.ReadFile(opts["--observed"])
			if err != nil {
				die(err)
			}
			if err := json.Unmarshal(b, &observed); err != nil {
				die(err)
			}
		}
		plan := planner.Build(f, observed)
		if opts["--out"] != "" {
			if err := writeJSONFile(opts["--out"], plan); err != nil {
				die(err)
			}
			fmt.Println(filepath.Clean(opts["--out"]))
		} else {
			out(plan)
		}

	case "apply":
		pos, _, flags, err := parseArgs(a[1:])
		if err != nil {
			die(err)
		}
		if len(pos) != 1 {
			die(errors.New("apply requires exactly one PLAN_FILE"))
		}
		requireYes(flags, "apply")
		p, err := readPlan(pos[0])
		if err != nil {
			die(err)
		}
		results, err := remote.ApplyPlan(load(), p)
		if err != nil {
			die(err)
		}
		out(results)

	case "backup":
		if len(a) < 3 {
			usage(); os.Exit(2)
		}
		switch a[1] {
		case "create":
			if len(a) != 3 {
				die(errors.New("backup create requires FILE"))
			}
			if err := store.Backup(a[2], load()); err != nil {
				die(err)
			}
			fmt.Println(filepath.Clean(a[2]))
		case "restore":
			pos, _, flags, err := parseArgs(a[2:])
			if err != nil {
				die(err)
			}
			if len(pos) != 1 {
				die(errors.New("backup restore requires FILE"))
			}
			requireYes(flags, "backup restore")
			f, err := store.Restore(pos[0])
			if err != nil {
				die(err)
			}
			out(f)
		default:
			usage(); os.Exit(2)
		}

	case "history":
		p, err := store.HistoryPath()
		if err != nil {
			die(err)
		}
		b, err := os.ReadFile(p)
		if errors.Is(err, os.ErrNotExist) {
			return
		}
		if err != nil {
			die(err)
		}
		fmt.Print(string(b))

	case "bridge":
		if len(a) > 1 && a[1] == "print" {
			fmt.Print(bridge.Script)
		} else {
			usage(); os.Exit(2)
		}

	default:
		usage()
		os.Exit(2)
	}
}
