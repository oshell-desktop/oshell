#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Read-only package/image validation. Does not install or launch the payload."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from release_targets import TARGETS, RELEASE_FLAVORS
import installer_metadata
import code_signing

ROOT = Path(__file__).resolve().parent.parent

def run(args):
    return subprocess.run(list(map(str, args)), capture_output=True, text=True, check=True).stdout

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def version_parts(value):
    return tuple((list(map(int, value.split('.'))) + [0, 0, 0])[:3])

def verify_deployment(relative, deployment, minimum):
    assert deployment, (str(relative), 'missing deployment target')
    expected = version_parts(minimum)
    versions = [version_parts(value) for value in deployment]
    # Upstream frameworks may support older systems. Our binaries must carry
    # the declared floor, so stale pre-migration products cannot pass validation.
    if relative.parts[0] == 'Frameworks':
        assert all(value <= expected for value in versions), (str(relative), deployment, minimum)
    else:
        assert all(value == expected for value in versions), (str(relative), deployment, minimum)

def verify_app(candidate, staged, target, expected):
    info = plistlib.loads((candidate/'Contents/Info.plist').read_bytes())
    assert not info.get('OShellTestHarness'), 'Release payload contains developer test hooks'
    for key in ['CFBundleShortVersionString', 'CFBundleVersion']:
        assert info[key] == expected[key], (key, 'stale app metadata')
    assert info['LSMinimumSystemVersion'] == target.minimum
    bridge = plistlib.loads((candidate/'Contents/Helpers/OShell-FileZilla.app/Contents/Info.plist').read_bytes())
    assert bridge['LSMinimumSystemVersion'] == target.minimum
    for resource in ['OShell-LICENSE.txt', 'OShell.icns', 'oshell-integration.sh', 'THIRD_PARTY_NOTICES.txt', 'ColorSchemes-LICENSE.txt', 'Sparkle-LICENSE.txt']:
        assert digest(candidate/'Contents/Resources'/resource) == digest(staged/'Contents/Resources'/resource)
    for relative in ['MacOS/OShell', 'MacOS/OShell-ZOC', 'Helpers/OShell-MCP', 'Helpers/OShellAskpass', 'Helpers/OShellProxy', 'Helpers/lrz', 'Helpers/lsz', 'Helpers/OShell-FileZilla.app/Contents/MacOS/OShell-FileZilla']:
        item = candidate/'Contents'/relative
        assert set(run(['lipo', '-archs', item]).split()) == set(target.architectures), (relative, 'wrong architecture')
        assert digest(item) == digest(staged/'Contents'/relative), (relative, 'stale payload')
    # Check every Mach-O, including bundled frameworks/runtimes, not just plist claims.
    for item in (candidate/'Contents').rglob('*'):
        if not item.is_file() or item.is_symlink():
            continue
        with item.open('rb') as stream:
            magic = stream.read(4)
        if magic not in [b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca']:
            continue
        assert set(run(['lipo', '-archs', item]).split()) == set(target.architectures), (str(item), 'wrong Mach-O architecture')
        build = run(['vtool', '-show-build', item])
        deployment = re.findall(r'^\s*minos\s+(\d+(?:\.\d+)*)', build, re.M) + re.findall(r'cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version (\d+(?:\.\d+)*)', build)
        verify_deployment(item.relative_to(candidate/'Contents'), deployment, target.minimum)
    run(['codesign', '--verify', '--deep', '--strict', candidate])
    if info.get(code_signing.MARKER): code_signing.verify(candidate)
    elif __import__('os').environ.get('OSHELL_REQUIRE_FIXED_SIGNING') == '1': raise ValueError('Official installer is not signed with the pinned certificate')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flavor', action='append', choices=list(TARGETS))
    parser.add_argument('--format', choices=['both', 'dmg'], default='both')
    parser.add_argument('--app-only', action='store_true', help='Validate staged apps without creating/installing packages')
    args = parser.parse_args()
    out = ROOT/'dist/installers'
    expected = plistlib.loads((ROOT/'scripts/Info.plist').read_bytes())
    version = expected['CFBundleShortVersionString']
    results = []
    for flavor in args.flavor or RELEASE_FLAVORS:
        target = TARGETS[flavor]
        staged = ROOT/'work/release'/flavor/'OShell.app'
        pkg = out/f'OShell-{version}-{target.suffix}.pkg'
        dmg = out/f'OShell-{version}-{target.suffix}.dmg'
        verify_app(staged, staged, target, expected)
        if not args.app_only:
            with tempfile.TemporaryDirectory(prefix='oshell-installer-verify-') as directory:
                temporary = Path(directory)
                if args.format == 'both':
                    expanded = temporary/'expanded'
                    run(['pkgutil', '--expand-full', pkg, expanded])
                    app = next(expanded.rglob('OShell.app'))
                    distribution = ET.parse(expanded/'Distribution').getroot()
                    assert distribution.find('.//os-version').attrib['min'] == target.minimum
                    assert set(distribution.find('options').attrib['hostArchitectures'].split(',')) == set(target.architectures)
                    verify_app(app, staged, target, expected)
                mount = temporary/'mount'; mount.mkdir()
                attached = False
                try:
                    run(['hdiutil', 'attach', '-nobrowse', '-readonly', '-mountpoint', mount, dmg]); attached = True
                    verify_app(mount/'OShell.app', staged, target, expected)
                    assert (mount/'Applications').is_symlink()
                    installer_metadata.verify(mount, version=version, build=str(expected['CFBundleVersion']), flavor=flavor, minimum=target.minimum, architectures=target.architectures)
                finally:
                    if attached:
                        run(['hdiutil', 'detach', mount])
        result = dict(flavor=flavor, passed=True, version=version, build=expected['CFBundleVersion'], minimumOS=target.minimum,
                      **code_signing.metadata(plistlib.loads((staged/'Contents/Info.plist').read_bytes())),
                      architectures=sorted(target.architectures), signaturesVerified=True, allMachOMinimumsVerified=True)
        if not args.app_only:
            result.update(dmg=dmg.name, dmgSHA256=digest(dmg), payloadMatchesStagedApp=True)
            if args.format == 'both': result['pkg'] = pkg.name
        results.append(result)
        print(flavor, 'app checks passed' if args.app_only else 'installer payload checks passed', flush=True)
    if not args.app_only:
        for line in (out/'SHA256SUMS.txt').read_text().splitlines():
            expected_hash, name = line.split('  ', 1)
            assert Path(name).name == name and digest(out/name) == expected_hash
    (ROOT/'validation').mkdir(exist_ok=True)
    (ROOT/'validation/package-installers-verification.json').write_text(json.dumps({'passed': True, 'packages': results}, indent=2))
    print('All checks passed')

if __name__ == '__main__':
    main()
