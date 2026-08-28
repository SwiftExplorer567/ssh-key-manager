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
	"github.com/SwiftExplorer567/ssh-key-manager/v2/internal/store"
)

const version = "2.0.0-beta.1"

func die(err error) { fmt.Fprintln(os.Stderr, "error:", err); os.Exit(1) }
func usage() {
	fmt.Print(`SSH Key Manager V2 beta

Usage:
  skm2 version
  skm2 init [NAME]
  skm2 status
  skm2 migrate v1 [V1_CONFIG_DIR] [--save]
  skm2 node list
  skm2 subject list
  skm2 credential list
  skm2 policy list
  skm2 plan --observed FILE
  skm2 backup create FILE
  skm2 backup restore FILE
  skm2 bridge print

V2 state is local-first. Private keys are never stored in state or backups.
Remote mutation is intentionally unavailable unless a restricted bridge is enrolled.
`)
}
func load() *model.Fleet {
	f, e := store.Load()
	if e != nil {
		if errors.Is(e, os.ErrNotExist) {
			die(fmt.Errorf("no V2 fleet; run skm2 init or skm2 migrate v1 --save"))
		}
		die(e)
	}
	return f
}
func out(v any) { b, _ := json.MarshalIndent(v, "", "  "); fmt.Println(string(b)) }
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
		name := "Default Fleet"
		if len(a) > 1 {
			name = strings.Join(a[1:], " ")
		}
		f, e := store.Init(name)
		if e != nil {
			die(e)
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
		dir := ""
		save := false
		for _, x := range a[2:] {
			if x == "--save" {
				save = true
			} else {
				dir = x
			}
		}
		r, e := migrate.FromV1(dir, "Migrated V1 Fleet")
		if e != nil {
			die(e)
		}
		out(r)
		if save {
			if e := store.Save(r.Fleet); e != nil {
				die(e)
			}
			fmt.Fprintln(os.Stderr, "saved V2 state; no remote SSH authorization changed")
		}
	case "node":
		if len(a) > 1 && a[1] == "list" {
			out(load().Nodes)
		} else {
			usage()
			os.Exit(2)
		}
	case "subject":
		if len(a) > 1 && a[1] == "list" {
			out(load().Subjects)
		} else {
			usage()
			os.Exit(2)
		}
	case "credential":
		if len(a) > 1 && a[1] == "list" {
			out(load().Credentials)
		} else {
			usage()
			os.Exit(2)
		}
	case "policy":
		if len(a) > 1 && a[1] == "list" {
			out(load().Policies)
		} else {
			usage()
			os.Exit(2)
		}
	case "plan":
		var p string
		for i := 1; i < len(a); i++ {
			if a[i] == "--observed" && i+1 < len(a) {
				p = a[i+1]
				i++
			}
		}
		if p == "" {
			die(errors.New("--observed FILE required in beta.1"))
		}
		b, e := os.ReadFile(p)
		if e != nil {
			die(e)
		}
		var obs []model.ObservedPrincipal
		if e = json.Unmarshal(b, &obs); e != nil {
			die(e)
		}
		plan := planner.Build(load(), obs)
		out(plan)
	case "backup":
		if len(a) != 3 {
			usage()
			os.Exit(2)
		}
		switch a[1] {
		case "create":
			if e := store.Backup(a[2], load()); e != nil {
				die(e)
			}
			fmt.Println(filepath.Clean(a[2]))
		case "restore":
			f, e := store.Restore(a[2])
			if e != nil {
				die(e)
			}
			out(f)
		default:
			usage()
			os.Exit(2)
		}
	case "bridge":
		if len(a) > 1 && a[1] == "print" {
			fmt.Print(bridge.Script)
		} else {
			usage()
			os.Exit(2)
		}
	default:
		usage()
		os.Exit(2)
	}
}
