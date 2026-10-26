#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Safety checks for local cleanup and the isolated UI test entry point."""
import importlib.util, plistlib, subprocess, tempfile, unittest
from pathlib import Path
from unittest.mock import patch
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parent.parent
def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT/'scripts'/f'{name}.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module
CLEAN = load('clean-local-builds')
UI = load('run-ui-tests')

class DevelopmentToolsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name)
    def tearDown(self): self.tmp.cleanup()
    def file(self, name):
        p = self.root/name; p.parent.mkdir(parents=True, exist_ok=True); p.write_text('fixture'); return p
    def test_cleanup_keeps_app_sources_keys_and_dependency_environment(self):
        keep = [self.file(p) for p in ['dist/OShell.app/Contents/MacOS/OShell','Sources/example.swift','.release-private/key','work/test-tools/bin/python','validation/.gitkeep','validation/latest-checks.json']]
        self.file('work/size-review/probe.dSYM/Contents/Resources/DWARF/probe')
        self.file('work/build/swift/object.o'); self.file('work/release/legacy/OShell.app/binary'); self.file('validation/old.log')
        paths = CLEAN.candidates(self.root)
        self.assertIn(self.root/'work/size-review', paths)
        self.assertIn(self.root/'work/build', paths)
        self.assertIn(self.root/'work/release', paths)
        for p in keep: self.assertFalse(any(p == q or q in p.parents for q in paths))
    def retained_app(self, name):
        app = self.root/'work'/name/'OShell.app'
        (app/'Contents').mkdir(parents=True)
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'app.oshell.mac'}))
        return app.parent
    def test_preserved_builds_require_known_bundle_and_no_other_files(self):
        old = self.retained_app('running-app-old')
        unrelated = self.retained_app('running-app-with-notes'); self.file('work/running-app-with-notes/notes.txt')
        self.file('work/running-app-unrelated/valuable.txt')
        self.assertIn(old, CLEAN.candidates(self.root))
        self.assertNotIn(unrelated, CLEAN.candidates(self.root))
        self.assertNotIn(self.root/'work/running-app-unrelated', CLEAN.candidates(self.root))
    def test_loaded_image_protects_renamed_running_bundle(self):
        old = self.retained_app('running-app-active')
        exe = self.root/'dist/OShell.app/Contents/MacOS/OShell'
        mapped = old/'OShell.app/Contents/MacOS/OShell'
        with patch.object(CLEAN.subprocess, 'check_output', return_value='42 '+str(exe)+'\n'), patch.object(CLEAN.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout='p42\nn'+str(mapped)+'\n')):
            active = CLEAN.active_paths(self.root)
        self.assertTrue(CLEAN.in_use(old, active))
    def test_failed_image_inspection_preserves_retained_apps(self):
        old = self.retained_app('running-app-protected')
        with patch.object(CLEAN.subprocess, 'check_output', return_value='42 '+str(self.root/'dist/OShell.app/Contents/MacOS/OShell')+'\n'), patch.object(CLEAN.subprocess, 'run', side_effect=FileNotFoundError):
            self.assertTrue(CLEAN.in_use(old, CLEAN.active_paths(self.root)))
    def test_cleanup_rejects_tracked_files(self):
        p = self.file('work/build/valuable.txt').parent
        with self.assertRaisesRegex(RuntimeError, 'tracked'):
            CLEAN.validate_targets(self.root, [p], ['work/build/valuable.txt'], [])
    def test_cleanup_keep_preserves_acceptance_and_only_current_test_app(self):
        kept = self.file('work/test-app/OShell.app/Contents/MacOS/OShell').parents[2]
        old = self.file('work/test-app/OShell-preview-old.app/Contents/MacOS/OShell').parents[2]
        acceptance = self.file('dist/acceptance/OShell.app/Contents/MacOS/OShell').parents[3]
        old_dmg = self.file('dist/old.dmg')
        report = self.file('validation/fullscreen-acceptance-report.json')
        paths = CLEAN.candidates(self.root, [kept, acceptance, report])
        for p in (kept, acceptance, report): self.assertFalse(any(p == q or q in p.parents for q in paths))
        self.assertIn(old, paths)
        self.assertIn(old_dmg, paths)
    def test_locked_desktop_is_rejected_before_ui_regression(self):
        data = plistlib.dumps([{'IOConsoleUsers':[{'CGSSessionOnConsoleKey':True,'CGSSessionScreenIsLocked':True}]}])
        with patch.object(UI.subprocess, 'check_output', return_value=data):
            with self.assertRaisesRegex(RuntimeError, 'Desktop is locked'): UI.require_unlocked_desktop()
    def test_inactive_locked_session_does_not_block_active_desktop(self):
        data = plistlib.dumps([{'IOConsoleUsers':[{'CGSSessionOnConsoleKey':False,'CGSSessionScreenIsLocked':True}, {'CGSSessionOnConsoleKey':True}]}])
        with patch.object(UI.subprocess, 'check_output', return_value=data): UI.require_unlocked_desktop()
    def test_cleanup_rejects_active_process(self):
        exe = self.file('work/test-app/OShell.app/Contents/MacOS/OShell')
        with self.assertRaisesRegex(RuntimeError, 'in use'):
            CLEAN.validate_targets(self.root, [self.root/'work/test-app'], [], [exe])
    def test_cleanup_rejects_app_and_project_root(self):
        for p in [self.root, self.root/'dist', self.root/'dist/OShell.app']:
            with self.assertRaises(RuntimeError): CLEAN.validate_targets(self.root, [p], [], [])
    def test_symlink_targets_are_not_traversed(self):
        outside = self.root/'outside'; outside.mkdir(); (outside/'keep').write_text('keep')
        link = self.root/'work/build'; link.parent.mkdir(); link.symlink_to(outside, target_is_directory=True)
        CLEAN.validate_targets(self.root, [link], [], [])
        link.unlink()
        self.assertEqual((outside/'keep').read_text(), 'keep')
    def test_ui_runner_rejects_production_app(self):
        app = self.root/'OShell.app'; (app/'Contents').mkdir(parents=True)
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps({}))
        with self.assertRaisesRegex(RuntimeError, 'test app first'): UI.run_case(app, 'terminal-clock', 1)
    def test_read_only_cache_can_be_cleaned_without_following_links(self):
        keep = self.file('outside/keep')
        cache = self.file('work/cache/module/file').parents[1]
        (cache/'module/alias').symlink_to(keep.parent, target_is_directory=True)
        (cache/'module').chmod(0o555); cache.chmod(0o555)
        CLEAN.remove_directory(cache)
        self.assertFalse(cache.exists()); self.assertEqual(keep.read_text(), 'fixture')
    def test_case_catalog_is_usable_without_an_app(self):
        output = subprocess.check_output(['python3', str(ROOT/'scripts/run-ui-tests.py'), '--list'], text=True)
        self.assertIn('directory-picker-stress', output); self.assertIn('encrypted-startup', output)
    def test_test_packages_are_rejected_before_building(self):
        result = subprocess.run(['python3', str(ROOT/'scripts/package-release.py'), '--tests'], capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn(b'requires --apps-only', result.stderr)

if __name__ == '__main__': unittest.main()
