// SPDX-License-Identifier: GPL-3.0-only
// Copied only into an isolated Desktop checkout by test-appearance-interop.py.
package core

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestSwiftAppearanceValidationParity(t *testing.T) {
	helper := os.Getenv("OSHELL_SWIFT_INTEROP_HELPER")
	if helper == "" {
		t.Fatal("real Swift helper is required; this regression must not be skipped")
	}
	vault, err := OpenVault(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	master := []byte("interop-fixture-master-🔐")
	if err = vault.SetMaster(string(master)); err != nil {
		t.Fatal(err)
	}
	base, _, err := vault.ExportSharedDocument(context.Background(), DefaultConfig(), master, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	seed, err := json.Marshal(base)
	if err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name       string
		appearance map[string]any
		valid      bool
	}{
		{"empty-defaults", map[string]any{}, true},
		{"sparse", map[string]any{"left": 17}, true},
		{"unicode", map[string]any{"asianFont": "字体🙂 e\u0301", "tabColor": "#AbCdEf"}, true},
		{"font-limit", map[string]any{"asianFont": strings.Repeat("字", 128)}, true},
		{"astral-font-limit", map[string]any{"asianFont": strings.Repeat("🙂", 128)}, true},
		{"combining-font-limit", map[string]any{"asianFont": strings.Repeat("e\u0301", 64)}, true},
		{"font-too-long", map[string]any{"asianFont": strings.Repeat("字", 129)}, false},
		{"unknown", map[string]any{"left": 17, "futureField": true}, false},
		{"unknown-null", map[string]any{"futureField": nil}, false},
		{"unknown-object", map[string]any{"futureField": map[string]any{"synthetic": true}}, false},
		{"range", map[string]any{"left": 129}, false},
		{"wrong-type", map[string]any{"left": true}, false},
		{"invalid-color", map[string]any{"tabColor": "#+12345"}, false},
	}
	for _, suffix := range []struct{ name, value string }{{"LF", "\n"}, {"CR", "\r"}, {"CRLF", "\r\n"}} {
		for _, field := range []struct{ key, value string }{{"asianFont", "Fixture CJK"}, {"tabColor", "#123456"}, {"tabColor", ""}} {
			cases = append(cases, struct {
				name       string
				appearance map[string]any
				valid      bool
			}{field.key + "-" + suffix.name + "-" + field.value, map[string]any{field.key: field.value + suffix.value}, false})
		}
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			run := func(mode string, input []byte, valid bool) []byte {
				t.Helper()
				in, out := filepath.Join(dir, mode+"-in.json"), filepath.Join(dir, mode+"-out.json")
				if err := os.WriteFile(in, input, 0600); err != nil {
					t.Fatal(err)
				}
				output, err := exec.Command(helper, mode, in, out).CombinedOutput()
				if !valid {
					if err == nil {
						t.Fatalf("Swift %s accepted invalid appearance", mode)
					}
					if _, err := os.Stat(out); !os.IsNotExist(err) {
						t.Fatal("rejected input produced output")
					}
					return nil
				}
				if err != nil {
					t.Fatalf("Swift %s: %v %s", mode, err, output)
				}
				data, err := os.ReadFile(out)
				if err != nil {
					t.Fatal(err)
				}
				return data
			}
			var object map[string]any
			if err := json.Unmarshal(seed, &object); err != nil {
				t.Fatal(err)
			}
			object["preferences"].(map[string]any)["terminalAppearance"] = tc.appearance
			raw, err := json.Marshal(object)
			if err != nil {
				t.Fatal(err)
			}
			canonical, err := canonicalConfigurationJSON(raw)
			if !tc.valid {
				if !errors.Is(err, ErrSharedProtocol) {
					t.Fatalf("Go accepted invalid appearance: %v", err)
				}
				for _, mode := range []string{"canonical-json", "model-json", "raw-model-json"} {
					run(mode, raw, false)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			for _, mode := range []string{"canonical-json", "model-json", "raw-model-json"} {
				back := run(mode, raw, true)
				normalized, err := canonicalConfigurationJSON(back)
				if err != nil {
					t.Fatal(err)
				}
				if !equalSharedJSON(canonical, normalized) {
					t.Fatalf("%s changed appearance or another configuration section", mode)
				}
				doc, err := decodeNativeDocument(normalized)
				if err != nil {
					t.Fatal(err)
				}
				cfg, err := doc.Configuration()
				if err != nil {
					t.Fatal(err)
				}
				next, _, err := vault.ExportSharedDocument(context.Background(), cfg, master, &doc, nil)
				if err != nil {
					t.Fatal(err)
				}
				nextRaw, err := json.Marshal(next)
				if err != nil {
					t.Fatal(err)
				}
				nextCanonical, err := canonicalConfigurationJSON(nextRaw)
				if err != nil {
					t.Fatal(err)
				}
				if !equalSharedJSON(canonical, nextCanonical) {
					t.Fatalf("Go model changed %s output", mode)
				}
				final := run("model-json", nextCanonical, true)
				if !equalSharedJSON(canonical, final) {
					t.Fatal("Swift-Go-Swift round trip changed the document")
				}
			}
		})
	}
}
