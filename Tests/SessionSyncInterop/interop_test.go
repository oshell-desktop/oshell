package core

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// Injected with go -overlay. The Desktop checkout is not edited.
func TestOShellSessionScopeCompatibility(t *testing.T) {
	helper := os.Getenv("OSHELL_SESSION_SCOPE_HELPER")
	if helper == "" {
		t.Fatal("native helper is required")
	}
	run := func(args ...string) {
		t.Helper()
		if out, e := exec.Command(helper, args...).CombinedOutput(); e != nil {
			t.Fatalf("native fixture: %v %s", e, out)
		}
	}
	ctx := context.Background()
	engine, cfg, master := syncEngineFixture(t, t.TempDir())
	cfg.Settings.FontSize = 17
	cfg.SessionDefaults.SSHPort = 2217
	if e := engine.Store.Save(cfg); e != nil {
		t.Fatal(e)
	}
	if e := engine.Vault.Put(cfg.Profiles[0], "fixture-session-password"); e != nil {
		t.Fatal(e)
	}
	plan, e := engine.Prepare(ctx, cfg, master, true)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = plan.Commit(ctx, nil, master); e != nil {
		t.Fatal(e)
	}
	remote, e := engine.Transport.Fetch(ctx)
	if e != nil {
		t.Fatal(e)
	}
	dir := t.TempDir()
	goFile := filepath.Join(dir, "desktop.json")
	local := filepath.Join(dir, "native-local.json")
	wire := filepath.Join(dir, "wire.json")
	back := filepath.Join(dir, "back.json")
	if e = os.WriteFile(goFile, remote.Data, 0600); e != nil {
		t.Fatal(e)
	}
	run("localize", goFile, local)
	run("publish", local, goFile, wire)
	native, e := os.ReadFile(wire)
	if e != nil {
		t.Fatal(e)
	}
	doc, e := DecodeSharedDocument(native, master)
	if e != nil {
		t.Fatal(e)
	}
	if string(doc.Preferences["fontSize"]) != "17" || doc.Defaults.SSHPort != 2217 || len(doc.QuickCommands) != 0 {
		t.Fatal("OShell exported its client settings")
	}
	if len(doc.Proxies) != 1 || len(doc.Links.Entries) != 1 || doc.Profiles[0].Definition.ProxyID != doc.Proxies[0].Definition.ID() {
		t.Fatal("session dependencies lost")
	}
	if e = engine.Transport.Put(ctx, native, remote.ETag); e != nil {
		t.Fatal(e)
	}
	plan, e = engine.Prepare(ctx, cfg, master, false)
	if e != nil {
		t.Fatal(e)
	}
	cfg, e = plan.Commit(ctx, nil, master)
	if e != nil {
		t.Fatal(e)
	}
	if cfg.Settings.FontSize != 17 || cfg.SessionDefaults.SSHPort != 2217 {
		t.Fatal("Desktop settings changed during native session update")
	}
	if secret, e := engine.Vault.GetFor(cfg.Profiles[0], cfg.Profiles[0].Identity()); e != nil || secret != "fixture-session-password" {
		t.Fatal("session credential lost", e)
	}
	cfg.Profiles[0].Name = "desktop-session-edit"
	cfg.Settings.FontSize = 19
	if e = engine.Store.Save(cfg); e != nil {
		t.Fatal(e)
	}
	plan, e = engine.Prepare(ctx, cfg, master, false)
	if e != nil {
		t.Fatal(e)
	}
	cfg, e = plan.Commit(ctx, nil, master)
	if e != nil {
		t.Fatal(e)
	}
	remote, e = engine.Transport.Fetch(ctx)
	if e != nil {
		t.Fatal(e)
	}
	os.WriteFile(goFile, remote.Data, 0600)
	run("apply", goFile, local, back)
	changed := filepath.Join(dir, "settings-only.json")
	unchanged := filepath.Join(dir, "unchanged.json")
	run("settings-only", back, changed)
	run("publish", changed, goFile, unchanged)
	unchangedData, e := os.ReadFile(unchanged)
	if e != nil || !bytes.Equal(unchangedData, remote.Data) {
		t.Fatal("client-only edit rewrote remote data", e)
	}
	// A legacy v1 full document is accepted; unknown full-document fields still fail closed.
	full, e := DecodeSharedDocument(remote.Data, master)
	if e != nil {
		t.Fatal(e)
	}
	plain, e := json.Marshal(full)
	if e != nil {
		t.Fatal(e)
	}
	legacy, e := SealShared(plain, master)
	if e != nil {
		t.Fatal(e)
	}
	legacyFile := filepath.Join(dir, "legacy.json")
	os.WriteFile(legacyFile, legacy, 0600)
	run("apply", legacyFile, local, back)
	var unknown map[string]any
	json.Unmarshal(plain, &unknown)
	unknown["futureUnsupportedSetting"] = true
	damaged, _ := json.Marshal(unknown)
	sealed, e := SealShared(damaged, master)
	if e != nil {
		t.Fatal(e)
	}
	invalid := filepath.Join(dir, "invalid.json")
	os.WriteFile(invalid, sealed, 0600)
	output := filepath.Join(dir, "must-not-exist.json")
	if exec.Command(helper, "apply", invalid, local, output).Run() == nil {
		t.Fatal("unknown data accepted")
	}
	if _, e = os.Stat(output); !os.IsNotExist(e) {
		t.Fatal("invalid data wrote local configuration")
	}
	sealed, e = SealShared(plain, []byte("incorrect-master"))
	if e != nil {
		t.Fatal(e)
	}
	os.WriteFile(invalid, sealed, 0600)
	if exec.Command(helper, "apply", invalid, local, output).Run() == nil {
		t.Fatal("incorrect master accepted")
	}
}
