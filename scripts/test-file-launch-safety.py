#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""The real FileZilla launcher must reject special files without blocking or opening UI."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--launcher', type=Path, default=ROOT/'work/test-app/OShell.app/Contents/Helpers/OShell-FileZilla.app/Contents/MacOS/OShell-FileZilla')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='oshell-launch-safety-') as directory:
        root = Path(directory)
        fifo = root/'sites.fifo'
        os.mkfifo(fifo, 0o600)
        empty = root/'empty.xml'
        empty.write_bytes(b'')
        link = root/'link.xml'
        link.symlink_to(empty)
        for path in [fifo, root, empty, link]:
            env = dict(os.environ, OSHELL_FILEZILLA_CONFIG=str(path), OSHELL_LAUNCH_NO_UI='1', OSHELL_DATA_DIR=str(root/'data'))
            start = time.monotonic()
            result = subprocess.run([str(args.launcher), '--site=0/fixture'], env=env,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
            assert result.returncode == 1, (path.name, result.returncode)
            assert time.monotonic() - start < 3, path.name
            assert not (root/'data').exists(), 'Invalid site must never launch a workspace'
    print('PASS: launcher rejects FIFO, directory, empty XML and symlink without blocking or launching UI')


if __name__ == '__main__':
    main()
