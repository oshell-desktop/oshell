#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Offline regression checks for native and translated release validation."""
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


PACK = load('macbook_pack', 'package-release.py')
CHECK = load('macbook_check', 'check-macbook-toolchain.py')


class MacBookReleaseTests(unittest.TestCase):
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
        temp = tempfile.TemporaryDirectory(prefix='oshell-macbook-tools-')
        self.addCleanup(temp.cleanup)
        self.developer = Path(temp.name)
        self.env_file = self.developer/'job.env'
        for context in [patch.dict(os.environ, {'OSHELL_DEVELOPER_DIR': str(self.developer)}, clear=True),
                        patch.object(CHECK.platform, 'system', return_value='Darwin'),
                        patch.object(CHECK.platform, 'machine', return_value='arm64')]:
            context.start()
            self.addCleanup(context.stop)

    def test_no_environment_export_if_rosetta_fails(self):
        def run(command, **kwargs):
            if command[0] == '/usr/bin/arch':
                raise subprocess.CalledProcessError(1, command)
        with patch.object(CHECK.subprocess, 'run', side_effect=run):
            with self.assertRaisesRegex(RuntimeError, 'Rosetta'):
                CHECK.check('intel', self.env_file)
        self.assertFalse(self.env_file.exists())

    def test_legacy_requires_bundled_runtime_before_export(self):
        swiftc = self.developer/'usr/bin/swiftc'
        with patch.object(CHECK.subprocess, 'run'), patch.object(CHECK.subprocess, 'check_output', return_value=str(swiftc)):
            with self.assertRaisesRegex(RuntimeError, 'pre-Swift-OS runtime'):
                CHECK.check('legacy', self.env_file)
        self.assertFalse(self.env_file.exists())

    def test_valid_toolchain_exports_job_local_path(self):
        with patch.object(CHECK.subprocess, 'run') as run:
            CHECK.check('arm64', self.env_file)
        self.assertEqual(self.env_file.read_text(), f'DEVELOPER_DIR={self.developer}\n')
        self.assertFalse(any(call.args[0][0] == '/usr/bin/arch' for call in run.call_args_list))
        self.assertTrue(all(call.kwargs['env']['DEVELOPER_DIR'] == str(self.developer) for call in run.call_args_list))

    def test_env_file_injection_is_rejected(self):
        with patch.dict(os.environ, {'OSHELL_DEVELOPER_DIR': str(self.developer)+'\nOTHER=value'}):
            with self.assertRaisesRegex(RuntimeError, 'absolute path'):
                CHECK.check('arm64', self.env_file)
        self.assertFalse(self.env_file.exists())

    def test_workflow_retains_all_targets_and_publication_gates(self):
        workflow = (ROOT/'.github/workflows/release.yml').read_text()
        build = workflow.split('\n  build:\n')[1].split('\n  release:\n')[0]
        self.assertIn('runs-on: [self-hosted, macOS, ARM64, self-macbook]', build)
        self.assertIn('max-parallel: 1', build)
        self.assertNotIn('container:', build)
        self.assertNotIn('OSHELL_ALLOW_ADHOC', build)
        for flavor in ['legacy', 'compat', 'arm64', 'intel']:
            self.assertIn(f'- flavor: {flavor}\n', build)
        for expected in ['--format dmg --test-core', 'scripts/verify-installers.py', 'OSHELL_REQUIRE_FIXED_SIGNING: "1"']:
            self.assertIn(expected, build)
        self.assertIn("if: needs.metadata.outputs.publish == 'true'", workflow.split('\n  release:\n')[1])
        self.assertIn('--build-only', workflow)


if __name__ == '__main__':
    unittest.main()
