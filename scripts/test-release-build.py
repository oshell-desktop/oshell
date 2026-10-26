#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Offline regression checks for hosted release validation."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT/'scripts'/filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PACK = load('release_pack', 'package-release.py')
CHECK = load('release_check', 'check-release-toolchain.py')
VERIFY = load('release_verify', 'verify-installers.py')


class ReleaseBuildTests(unittest.TestCase):
    def test_stale_or_too_new_app_binaries_are_rejected(self):
        for minimum in ['10.13', '13.0', '16.0']:
            with self.assertRaises(AssertionError):
                VERIFY.verify_deployment(Path('MacOS/OShell'), [minimum], '15.0')
        VERIFY.verify_deployment(Path('MacOS/OShell'), ['15.0'], '15.0')

    def test_framework_floor_must_not_exceed_supported_system(self):
        VERIFY.verify_deployment(Path('Frameworks/Sparkle'), ['10.13'], '15.0')
        for versions in [[], ['16.0']]:
            with self.assertRaises(AssertionError):
                VERIFY.verify_deployment(Path('Frameworks/Sparkle'), versions, '15.0')

    def test_intel_core_checks_are_executed_via_rosetta(self):
        binary = Path('/synthetic/intel')
        self.assertEqual(PACK.core_check_command({'x86_64': binary}, 'arm64'),
                         ['/usr/bin/arch', '-x86_64', binary/'OShellCoreChecks'])

    def test_native_core_checks_run_directly(self):
        native = Path('/synthetic/arm64')
        self.assertEqual(PACK.core_check_command({'arm64': native}, 'arm64'),
                         [native/'OShellCoreChecks'])

    def test_unsupported_host_does_not_skip_core_checks(self):
        with self.assertRaises(RuntimeError):
            PACK.core_check_command({'arm64': Path('/synthetic/arm64')}, 'x86_64')

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='oshell-release-tools-')
        self.addCleanup(temp.cleanup)
        self.developer = Path(temp.name)
        self.env_file = self.developer/'job.env'
        for context in [patch.dict(os.environ, {'DEVELOPER_DIR': str(self.developer)}, clear=True),
                        patch.object(CHECK.platform, 'system', return_value='Darwin'),
                        patch.object(CHECK.platform, 'machine', return_value='arm64')]:
            context.start()
            self.addCleanup(context.stop)

    def test_wrong_host_architecture_is_rejected_before_cache_export(self):
        with self.assertRaisesRegex(RuntimeError, 'native target architecture'):
            CHECK.check('amd64', self.env_file)
        self.assertFalse(self.env_file.exists())

    def test_valid_toolchain_exports_cache_keys_without_global_changes(self):
        with patch.object(CHECK.subprocess, 'run') as run, patch.object(CHECK, 'cache_keys', return_value=('prefix', 'prefix-source')):
            CHECK.check('arm64', self.env_file)
        self.assertEqual(self.env_file.read_text(), 'cache-prefix=prefix\ncache-key=prefix-source\n')
        self.assertFalse(any(call.args[0][0] in ('sudo', 'xcode-select') for call in run.call_args_list))

    def test_env_file_injection_is_rejected(self):
        with patch.dict(os.environ, {'DEVELOPER_DIR': str(self.developer)+'\nOTHER=value'}):
            with self.assertRaisesRegex(RuntimeError, 'absolute'):
                CHECK.check('arm64', self.env_file)
        self.assertFalse(self.env_file.exists())

    def test_source_changes_keep_restore_prefix_but_configuration_changes_do_not(self):
        (self.developer/'Sources').mkdir()
        source = self.developer/'Sources/Fixture.swift'; source.write_text('first')
        manifest = self.developer/'Package.swift'; manifest.write_text('manifest')
        with patch.object(CHECK, 'ROOT', self.developer), patch.object(CHECK, 'toolchain_identity', return_value={'sdk':'fixture'}):
            prefix, key = CHECK.cache_keys('arm64')
            source.write_text('second')
            next_prefix, next_key = CHECK.cache_keys('arm64')
            self.assertEqual(prefix, next_prefix)
            self.assertNotEqual(key, next_key)
            manifest.write_text('changed manifest')
            self.assertNotEqual(prefix, CHECK.cache_keys('arm64')[0])
            self.assertNotEqual(CHECK.cache_keys('arm64')[0], CHECK.cache_keys('amd64')[0])

    def test_packaging_changes_reuse_cache_but_helper_source_updates_archive(self):
        (self.developer/'scripts').mkdir()
        with patch.object(CHECK, 'ROOT', self.developer), patch.object(CHECK, 'toolchain_identity', return_value={'sdk':'fixture'}):
            prefix, key = CHECK.cache_keys('arm64')
            (self.developer/'scripts/package-release.py').write_text('DMG metadata only')
            self.assertEqual((prefix, key), CHECK.cache_keys('arm64'))
            (self.developer/'scripts/release_helpers.py').write_text('helper compiler flags')
            self.assertEqual(prefix, CHECK.cache_keys('arm64')[0])
            self.assertNotEqual(key, CHECK.cache_keys('arm64')[1])

    def test_workflow_retains_all_targets_and_publication_gates(self):
        workflow = (ROOT/'.github/workflows/release.yml').read_text()
        build = workflow.split('\n  build:\n')[1].split('\n  release:\n')[0]
        self.assertIn('runs-on: ${{ matrix.runner }}', build)
        self.assertIn('max-parallel: 2', build)
        self.assertNotIn('container:', build)
        self.assertNotIn('OSHELL_ALLOW_ADHOC', build)
        for flavor in ['amd64', 'arm64']:
            self.assertIn(f'- flavor: {flavor}\n', build)
        for flavor in ['legacy', 'compat', 'intel', 'modern']:
            self.assertNotIn(f'- flavor: {flavor}\n', build)
        for expected in ['--format dmg --test-core', 'scripts/verify-installers.py', 'OSHELL_REQUIRE_FIXED_SIGNING: "1"']:
            self.assertIn(expected, build)
        self.assertIn("if: needs.metadata.outputs.publish == 'true'", workflow.split('\n  release:\n')[1])
        self.assertIn('--build-only', workflow)


if __name__ == '__main__':
    unittest.main()
