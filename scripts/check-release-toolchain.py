#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Validate the hosted macOS toolchain and emit isolated Actions cache keys."""
import argparse
import os
from pathlib import Path
import platform
import subprocess
from compilation_cache import source_key, toolchain_identity, swift_source_inputs, swift_configuration_inputs
from release_targets import TARGETS, RELEASE_FLAVORS

ROOT = Path(__file__).resolve().parent.parent


def cache_keys(flavor):
    target = TARGETS[flavor]
    variant = dict(flavor=flavor, architectures=target.architectures, minimum=target.minimum, tests=False)
    tools = toolchain_identity()
    configuration = source_key(ROOT, swift_configuration_inputs(), variant, tools)
    sources = source_key(ROOT, swift_source_inputs(ROOT) + ['Vendor/lrzsz-0.12.20.tar.gz', 'scripts/release_helpers.py'], variant, tools)
    prefix = f'oshell-build-v4-{platform.machine()}-{flavor}-{configuration}'
    return prefix, f'{prefix}-{sources}'


def check(flavor, github_output=None):
    if platform.system() != 'Darwin' or platform.machine() not in TARGETS[flavor].architectures:
        raise RuntimeError('Release validation requires macOS with a native target architecture')
    developer = os.environ.get('DEVELOPER_DIR', '').strip()
    if '\n' in developer or '\r' in developer or not Path(developer).is_absolute() or not Path(developer).is_dir():
        raise RuntimeError('DEVELOPER_DIR must be an existing absolute Xcode developer directory')
    for command in [['xcodebuild', '-version'], ['xcrun', 'swift', '--version'],
                    ['xcrun', '--sdk', 'macosx', '--show-sdk-version']]:
        subprocess.run(command, check=True)
    for tool in ['swiftc', 'clang', 'vtool']:
        subprocess.run(['xcrun', '--find', tool], check=True, stdout=subprocess.DEVNULL)
    if github_output:
        prefix, key = cache_keys(flavor)
        with Path(github_output).open('a') as stream:
            stream.write(f'cache-prefix={prefix}\ncache-key={key}\n')
    print(f'Toolchain prerequisites passed for {flavor}; installer validation still required.', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--flavor', choices=RELEASE_FLAVORS, required=True)
    parser.add_argument('--github-output')
    args = parser.parse_args()
    try:
        check(args.flavor, args.github_output)
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error)+'\n')
