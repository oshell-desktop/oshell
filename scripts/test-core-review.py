#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Compile actual core sources and run review regressions in a disposable directory."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument('--appearance', action='store_true', help='run appearance/codec regressions only')
    selection.add_argument('--all', action='store_true', help='also run the complete core checks')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='oshell-core-review-') as directory:
        work = Path(directory)
        swift = ['swiftc', '-swift-version', '5', '-O', '-whole-module-optimization', '-module-cache-path', str(work/'modules')]
        subprocess.run(swift + ['-emit-library', '-emit-module', '-module-name', 'OShellCore',
                               *map(str, sorted((ROOT/'Sources/OShellCore').glob('*.swift'))),
                               '-o', str(work/'libOShellCore.dylib'),
                               '-emit-module-path', str(work/'OShellCore.swiftmodule')], check=True, cwd=ROOT)
        binary = work/'OShellCoreChecks'
        subprocess.run(swift + ['-parse-as-library', '-I', str(work), '-L', str(work), '-lOShellCore',
                               '-Xlinker', '-rpath', '-Xlinker', str(work),
                               *map(str, sorted((ROOT/'Tests/OShellCoreTests').glob('*.swift'))),
                               '-o', str(binary)], check=True, cwd=ROOT)
        env = dict(os.environ, OSHELL_DATA_DIR=str(work/'data'))
        subprocess.run([str(binary), '--appearance-checks' if args.appearance else '--review-checks'], check=True, cwd=ROOT, env=env, timeout=120)
        if args.all:
            subprocess.run([str(binary)], check=True, cwd=ROOT, env=env, timeout=600)


if __name__ == '__main__':
    main()
