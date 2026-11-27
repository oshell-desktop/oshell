#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Publish a fully assembled local app without modifying running code in place."""
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
import uuid


def publish(source: Path, target: Path, running: list[str]) -> Path:
    source, target = source.resolve(), target.absolute()
    executable = 'oTerm' if source.name == 'oTerm.app' else 'OShell'
    if executable == 'oTerm' and (target.exists() or target.is_symlink()):
        if target.is_symlink() or plistlib.loads((target/'Contents/Info.plist').read_bytes()).get('CFBundleIdentifier') != 'app.oshell.local-terminal':
            raise ValueError('Another application already uses the terminal destination.')
    if not (source/'Contents/MacOS'/executable).is_file():
        raise ValueError('The staged OShell app is incomplete.')
    target.parent.mkdir(parents=True, exist_ok=True)
    helper = str(target / 'Contents/Helpers/OShell-MCP')
    if any(path.startswith(str(target) + '/') and path != helper for path in running):
        target = target.with_name(target.stem + '-preview-' + uuid.uuid4().hex[:8] + '.app')
    # Rename entire directories; never truncate an executable mapped by another
    # process. Preserve the original on failure. Staging is on the same volume.
    # OShell-MCP is statically linked against our code/SDK and reads no bundle
    # resources. Unlinking its old image leaves the kernel's mapped vnode alive;
    # never terminate it or overwrite its inode. Its STDIO belongs to the client.
    previous = source.parent / ('previous-' + uuid.uuid4().hex + '.app')
    existed = target.exists()
    if existed:
        os.rename(target, previous)
    try:
        os.rename(source, target)
    except BaseException:
        if existed:
            os.rename(previous, target)
        raise
    if existed:
        shutil.rmtree(previous)
    return target


def main():
    source, target = map(Path, sys.argv[1:])
    # A failed inventory must not be treated as "nothing is running".
    output = subprocess.run(['/bin/ps', '-axo', 'comm='], text=True, capture_output=True, check=True).stdout
    running = [line.strip() for line in output.splitlines() if line.strip()]
    result = publish(source, target, running)
    if result != target.absolute():
        print('Running app preserved; the new build uses a separate preview path.', file=sys.stderr)
    print(result)


if __name__ == '__main__':
    main()
