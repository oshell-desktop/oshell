#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Package the shared terminal implementation as an independent Dock application."""
import argparse
import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

import code_signing

ROOT = Path(__file__).resolve().parent.parent
APP_NAME = 'oTerm.app'
IDENTIFIER = 'app.oshell.local-terminal'
EXECUTABLE = 'oTerm'


def build(directory, architecture, minimum, host=None, embed_update=False):
    contents = (host or directory/'OShell.app')/'Contents'
    if subprocess.check_output(['lipo', '-archs', contents/'MacOS/OShell'], text=True).split() != [architecture]:
        raise ValueError('The terminal and workspace architectures must match')
    info = plistlib.loads((ROOT/'scripts/Info.plist').read_bytes())
    directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=directory, prefix='.oshell-build-') as raw:
        stage = Path(raw)
        app = stage/APP_NAME
        resources = app/'Contents/Resources'
        resources.mkdir(parents=True)
        binary = app/'Contents/MacOS'/EXECUTABLE
        binary.parent.mkdir()
        metadata = dict(CFBundleName=APP_NAME[:-4], CFBundleDisplayName=APP_NAME[:-4],
                        CFBundleIdentifier=IDENTIFIER, CFBundleExecutable=EXECUTABLE,
                        CFBundlePackageType='APPL', CFBundleIconFile='LocalTerminal.icns',
                        OShellHostBundleIdentifier=info['CFBundleIdentifier'], OShellOwnsLocalWindows=True,
                        CFBundleShortVersionString=info['CFBundleShortVersionString'],
                        CFBundleVersion=info['CFBundleVersion'], LSMinimumSystemVersion=minimum)
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps(metadata))
        for mode in ('local-terminal', 'workspace', 'focus-workspace'):
            (resources/(mode+'.oshellwindow')).write_text(mode+'\n')
        iconset = stage/'LocalTerminal.iconset'
        subprocess.run(['swift', ROOT/'scripts/icon.swift', iconset, '--local-terminal'], check=True)
        subprocess.run(['iconutil', '-c', 'icns', iconset, '-o', resources/'LocalTerminal.icns'], check=True)
        shutil.copy2(contents/'MacOS/OShell', binary)
        shutil.copytree(contents/'Frameworks', app/'Contents/Frameworks', symlinks=True)
        for item in (contents/'Resources').iterdir():
            if item.suffix == '.bundle': shutil.copytree(item, resources/item.name, symlinks=True)
            elif item.name not in ('OShell.icns', 'LocalTerminal.zip'): shutil.copy2(item, resources/item.name)
        helpers = app/'Contents/Helpers'
        helpers.mkdir()
        for name in ('lrz', 'lsz', 'rz', 'sz'):
            shutil.copy2(contents/'Helpers'/name, helpers/name, follow_symlinks=False)
        code_signing.sign_app(app)
        if embed_update:
            # Seal the exact signed companion into the host before its final signature.
            archive = contents/'Resources/LocalTerminal.zip'
            subprocess.run(['/usr/bin/ditto', '-c', '-k', '--keepParent', app, archive], check=True)
            host_plist = contents/'Info.plist'
            host_info = plistlib.loads(host_plist.read_bytes())
            host_info['OShellLocalTerminalArchiveSHA256'] = hashlib.sha256(archive.read_bytes()).hexdigest()
            host_plist.write_bytes(plistlib.dumps(host_info))
        target = directory/APP_NAME
        if target.exists() and plistlib.loads((target/'Contents/Info.plist').read_bytes())['CFBundleIdentifier'] != IDENTIFIER:
            raise ValueError(f'Another application already uses {target}')
        subprocess.run([sys.executable, ROOT/'scripts/install-local-app.py', app, target], check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('architecture', choices=['arm64', 'x86_64'])
    parser.add_argument('minimum')
    parser.add_argument('--host', type=Path)
    parser.add_argument('--embed-update', action='store_true', help='Embed installer before signing the staged host')
    args = parser.parse_args()
    build(args.directory.resolve(), args.architecture, args.minimum, args.host, args.embed_update)
