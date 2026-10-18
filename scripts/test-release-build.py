#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Offline regression checks for hosted release validation."""
import importlib.util
import os
from pathlib import Path
import subprocess
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


class ReleaseBuildTests(unittest.TestCase):
    def test_intel_core_checks_are_executed_via_rosetta(self):
        binary = Path('/synthetic/intel')
        self.assertEqual(PACK.core_check_command({'x86_64': binary}, 'arm64'),
                         ['/usr/bin/arch', '-x86_64', binary/'OShellCoreChecks'])

    def test_universal_core_checks_prefer_native_slice(self):
        native = Path('/synthetic/arm64')
        self.assertEqual(PACK.core_check_command({'arm64': native, 'x86_64': Path('/synthetic/intel')}, 'arm64'),
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
            CHECK.check('intel', self.env_file)
        self.assertFalse(self.env_file.exists())

    def test_legacy_requires_bundled_runtime_before_export(self):
        swiftc = self.developer/'usr/bin/swiftc'
        with patch.object(CHECK.platform, 'machine', return_value='x86_64'), patch.object(CHECK.subprocess, 'run'), patch.object(CHECK.subprocess, 'check_output', return_value=str(swiftc)):
            with self.assertRaisesRegex(RuntimeError, 'pre-Swift-OS runtime'):
                CHECK.check('legacy', self.env_file)
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
            self.assertNotEqual(CHECK.cache_keys('arm64')[0], CHECK.cache_keys('compat')[0])

    def test_workflow_retains_all_targets_and_publication_gates(self):
        workflow = (ROOT/'.github/workflows/release.yml').read_text()
        build = workflow.split('\n  build:\n')[1].split('\n  release:\n')[0]
        self.assertIn('runs-on: ${{ matrix.runner }}', build)
        self.assertIn('max-parallel: 2', build)
        self.assertNotIn('container:', build)
        self.assertNotIn('OSHELL_ALLOW_ADHOC', build)
        for flavor in ['legacy', 'arm64']:
            self.assertIn(f'- flavor: {flavor}\n', build)
        for flavor in ['compat', 'intel']:
            self.assertNotIn(f'- flavor: {flavor}\n', build)
        for expected in ['--format dmg --test-core', 'scripts/verify-installers.py', 'OSHELL_REQUIRE_FIXED_SIGNING: "1"']:
            self.assertIn(expected, build)
        self.assertIn("if: needs.metadata.outputs.publish == 'true'", workflow.split('\n  release:\n')[1])
        self.assertIn('--build-only', workflow)


if __name__ == '__main__':
    unittest.main()
