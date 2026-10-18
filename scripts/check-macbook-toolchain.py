#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Preflight the native macOS runner without installing or changing system tools."""
import argparse
import os
from pathlib import Path
import platform
import subprocess
from release_targets import TARGETS, RELEASE_FLAVORS


def check(flavor, github_env=None):
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise RuntimeError('self-macbook requires native macOS ARM64')
    override = os.environ.get('OSHELL_DEVELOPER_DIR', '').strip()
    developer = override or subprocess.check_output(['xcode-select', '-p'], text=True).strip()
    if '\n' in developer or '\r' in developer or not Path(developer).is_absolute() or not Path(developer).is_dir():
        raise RuntimeError('Developer directory must be an existing absolute path')
    env = dict(os.environ, DEVELOPER_DIR=developer)
    for command in [['xcrun', 'swift', '--version'], ['xcrun', '--sdk', 'macosx', '--show-sdk-version']]:
        subprocess.run(command, env=env, check=True)
    for tool in ['swiftc', 'clang', 'vtool', 'swift-stdlib-tool']:
        subprocess.run(['xcrun', '--find', tool], env=env, check=True, stdout=subprocess.DEVNULL)
    if 'x86_64' in TARGETS[flavor].architectures:
        try:
            subprocess.run(['/usr/bin/arch', '-x86_64', '/usr/bin/true'], check=True)
        except subprocess.CalledProcessError as error:
            raise RuntimeError('Intel target validation requires Rosetta; install it on the runner and retry') from error
    if flavor == 'legacy':
        swiftc = Path(subprocess.check_output(['xcrun', '--find', 'swiftc'], env=env, text=True).strip())
        runtime = swiftc.parent.parent/'lib/swift-5.0/macosx/libswiftCore.dylib'
        if not runtime.is_file():
            raise RuntimeError('macOS 10.13 requires the pre-Swift-OS runtime; select a compatible toolchain such as Xcode 16.4 using OSHELL_DEVELOPER_DIR')
    # Persist only a non-secret toolchain path, scoped to later steps in this job.
    if github_env:
        with Path(github_env).open('a') as stream:
            stream.write(f'DEVELOPER_DIR={developer}\n')
    print(f'Toolchain prerequisites passed for {flavor}; DMG deployment validation still required.', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--flavor', choices=RELEASE_FLAVORS, required=True)
    parser.add_argument('--github-env')
    args = parser.parse_args()
    try:
        check(args.flavor, args.github_env)
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error)+'\n')
