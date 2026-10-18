#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Validate tag builds, collect two verified DMGs, and publish a complete Release."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET
from release_targets import TARGETS, RELEASE_FLAVORS
import code_signing

ROOT = Path(__file__).resolve().parent.parent

def sha256(path):
    with path.open('rb') as stream:
        digest = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
        return digest.hexdigest()

def validate_tag(tag, version):
    if not re.fullmatch(r'v\d+\.\d+\.\d+', tag) or tag != 'v' + version:
        raise ValueError(f'Release tag {tag!r} must match scripts/Info.plist: v{version}. For a manual run, leave tag empty to use this version.')

def metadata(tag, commit=None, allow_missing_tag=False, build_only=False):
    info = plistlib.loads((ROOT/'scripts/Info.plist').read_bytes())
    version, build = info['CFBundleShortVersionString'], str(info['CFBundleVersion'])
    if (allow_missing_tag or build_only) and not tag: tag = 'v' + version
    validate_tag(tag, version)
    if not build.isdigit() or int(build) < 1:
        raise ValueError('CFBundleVersion must be a positive, increasing integer')
    def git(*args):
        return subprocess.check_output(['git', '-C', str(ROOT), *args], text=True).strip()
    head = git('rev-parse', 'HEAD')
    ref = subprocess.run(['git', '-C', str(ROOT), 'rev-parse', '--verify', '--quiet', 'refs/tags/' + tag + '^{commit}'], capture_output=True, text=True)
    if ref.returncode and not (allow_missing_tag or build_only):
        raise ValueError(f'Release tag {tag} does not exist. Run the workflow manually from the source branch to create it.')
    if (not build_only and not ref.returncode and ref.stdout.strip() != head) or (commit and commit != head):
        raise ValueError('Release tag, selected branch/tag and requested commit must match; existing tags are never moved. Select the original tag to retry, or increment the version for a new release.')
    return dict(tag=tag, version=version, build=build, commit=head)

def prepare(tag, repository):
    """Manual runs pin the selected source commit, including first-time releases."""
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Repository must be owner/repo')
    meta = metadata(tag, allow_missing_tag=True)
    endpoint = f"repos/{repository}/git/ref/tags/{meta['tag']}"
    existing = gh('api', endpoint, check=False)
    if existing.returncode:
        if 'HTTP 404' not in existing.stderr: raise RuntimeError(existing.stderr)
        # POST only: never patch/force-update an existing ref, including races.
        created = gh('api', f'repos/{repository}/git/refs', '--method', 'POST',
                     '-f', 'ref=refs/tags/' + meta['tag'], '-f', 'sha=' + meta['commit'], check=False)
        if created.returncode and 'HTTP 422' not in created.stderr: raise RuntimeError(created.stderr)
    verify_remote_tag(repository, meta['tag'], meta['commit'])
    # Downstream metadata validation also requires a local immutable tag.
    ref = subprocess.run(['git', '-C', str(ROOT), 'show-ref', '--verify', '--quiet', 'refs/tags/' + meta['tag']])
    if ref.returncode:
        subprocess.run(['git', '-C', str(ROOT), 'tag', meta['tag'], meta['commit']], check=True)
    return metadata(meta['tag'], meta['commit'])

def artifact_name(version, flavor):
    return f'OShell-{version}-{TARGETS[flavor].suffix}.dmg'

def stage(meta, flavor, output):
    target = TARGETS[flavor]
    name = artifact_name(meta['version'], flavor)
    dmg = ROOT/'dist/installers'/name
    report = json.loads((ROOT/'validation/package-installers-verification.json').read_text())
    entries = [value for value in report.get('packages', []) if value.get('flavor') == flavor]
    if not report.get('passed') or len(entries) != 1:
        raise ValueError('Missing successful installer verification for ' + flavor)
    entry = entries[0]
    expected = dict(version=meta['version'], build=meta['build'], minimumOS=target.minimum, architectures=sorted(target.architectures), dmg=name)
    if any(entry.get(key) != value for key, value in expected.items()) or not all(entry.get(key) for key in ['passed', 'signaturesVerified', 'allMachOMinimumsVerified', 'payloadMatchesStagedApp']):
        raise ValueError('Stale or incomplete package verification for ' + flavor)
    if entry.get('dmgSHA256') != sha256(dmg):
        raise ValueError('DMG changed after validation')
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError('Artifact output must be empty')
    shutil.copy2(dmg, output/name)
    manifest = dict(meta, flavor=flavor, file=name, sha256=sha256(dmg), size=dmg.stat().st_size, verification=entry)
    (output/'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')

def collect_updates(meta, artifacts, repository, installers):
    if {path.name for path in artifacts.iterdir()} != {'updates-' + flavor for flavor in RELEASE_FLAVORS}:
        raise ValueError('Signed DMG metadata for both release targets is required')
    notes = []
    sparkle = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
    for flavor in RELEASE_FLAVORS:
        folder = artifacts/('updates-' + flavor)
        if {path.name for path in folder.iterdir()} != {flavor + '.json'}: raise ValueError('Unexpected update metadata files')
        record = json.loads((folder/(flavor + '.json')).read_text())
        expected = next(value for value in installers if value['flavor'] == flavor)
        fields = dict(format='OShell.release-update.v1', version=meta['version'], build=meta['build'], tag=meta['tag'], repository=repository, flavor=flavor, file=expected['file'], sha256=expected['sha256'], size=expected['size'])
        if any(record.get(key) != value for key,value in fields.items()): raise ValueError('Signed update metadata does not match the verified DMG')
        data = base64.b64decode(record['signedFeed'], validate=True)
        if len(data) > 32768 or b'<!DOCTYPE' in data.upper() or b'<!ENTITY' in data.upper(): raise ValueError('Invalid update metadata')
        items = ET.fromstring(data).findall('./channel/item')
        if len(items)!=1: raise ValueError('Expected one signed update item')
        item=items[0]; enclosure=item.find('enclosure')
        if item.findtext(sparkle+'version') != meta['build'] or item.findtext(sparkle+'shortVersionString') != meta['version'] or item.findtext(sparkle+'minimumSystemVersion') != TARGETS[flavor].minimum:
            raise ValueError('Signed update version or deployment target mismatch')
        if enclosure is None or enclosure.get('url') != f"https://github.com/{repository}/releases/download/{meta['tag']}/{expected['file']}" or enclosure.get('length') != str(expected['size']) or len(base64.b64decode(enclosure.get(sparkle+'edSignature', ''), validate=True)) != 64:
            raise ValueError('Signed update enclosure does not match DMG')
        notes.append(f"<!-- oshell-update-v1:{TARGETS[flavor].suffix}:{record['signedFeed']} -->")
    return notes

def release_changes(version):
    """Publish only this version's curated notes, not the full changelog."""
    path = ROOT/'CHANGELOG.md'
    if not path.is_file(): raise ValueError('CHANGELOG.md is required for release notes')
    sections = re.split(r'^##[ \t]+(.+?)[ \t]*$', path.read_text(encoding='utf-8'), flags=re.MULTILINE)
    matches = [sections[index + 1].strip() for index in range(1, len(sections), 2) if sections[index].strip() == version]
    if len(matches) != 1 or not matches[0]:
        raise ValueError(f'CHANGELOG.md must contain one non-empty section for {version}')
    return matches[0]

def collect(meta, artifacts, source, output, updates_artifacts=None, repository=""):
    expected_dirs = {'dmg-' + flavor for flavor in RELEASE_FLAVORS}
    if {path.name for path in artifacts.iterdir()} != expected_dirs:
        raise ValueError('Exactly two build artifacts are required; missing or unexpected artifacts found')
    records = []
    for flavor in RELEASE_FLAVORS:
        folder = artifacts/('dmg-' + flavor)
        record = json.loads((folder/'manifest.json').read_text())
        name = artifact_name(meta['version'], flavor)
        target = TARGETS[flavor]
        verification = record.get('verification', {})
        if any(record.get(key) != value for key, value in meta.items()) or record.get('flavor') != flavor or record.get('file') != name:
            raise ValueError('Mixed versions/commits in build artifacts')
        if any(verification.get(key) != value for key, value in dict(minimumOS=target.minimum, architectures=sorted(target.architectures), version=meta['version'], build=meta['build'], dmg=name).items()):
            raise ValueError('Unexpected platform verification')
        if not all(verification.get(key) for key in ['passed', 'signaturesVerified', 'allMachOMinimumsVerified', 'payloadMatchesStagedApp']):
            raise ValueError('Unverified installer')
        dmg = folder/name
        if dmg.is_symlink() or sha256(dmg) != record.get('sha256') or dmg.stat().st_size != record.get('size') or verification.get('dmgSHA256') != record.get('sha256'):
            raise ValueError('Artifact integrity check failed for ' + flavor)
        if {path.name for path in folder.iterdir()} != {name, 'manifest.json'}:
            raise ValueError('Unexpected files in artifact')
        records.append(record)
    if source.name != f"OShell-{meta['version']}-source.tar.gz" or not source.is_file() or source.is_symlink():
        raise ValueError('Expected the audited source archive for this version')
    updates = collect_updates(meta, updates_artifacts, repository, records) if updates_artifacts else []
    changes = release_changes(meta['version'])
    signatures = {(r['verification'].get('signing', 'ad-hoc'), r['verification'].get('codeSigningCertificateSHA256')) for r in records}
    if len(signatures) != 1: raise ValueError('Installers use different signing identities')
    signing, certificate = signatures.pop()
    signing_label = '固定自签名证书' if signing == 'self-signed' else 'ad-hoc 签名'
    if signing not in ('self-signed', 'ad-hoc'): raise ValueError('Unknown signing scheme')
    if signing == 'self-signed' and certificate != code_signing.profile()['sha256']: raise ValueError('Release certificate does not match the pinned identity')
    if os.environ.get('OSHELL_REQUIRE_FIXED_SIGNING') == '1' and signing != 'self-signed': raise ValueError('Official release requires fixed signing')
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError('Release output must be empty')
    for record in records:
        shutil.copy2(artifacts/('dmg-' + record['flavor'])/record['file'], output/record['file'])
    shutil.copy2(source, output/source.name)
    release_manifest = dict(meta, signing=signing, codeSigningCertificateSHA256=certificate, notarized=False, installers=records,
                            source=dict(file=source.name, sha256=sha256(source)))
    if updates: release_manifest['updateMetadata'] = 'embedded-in-release-notes-v1'
    (output/'release-manifest.json').write_text(json.dumps(release_manifest, indent=2) + '\n')
    assets = sorted(output.iterdir())
    (output/'SHA256SUMS.txt').write_text(''.join(f'{sha256(path)}  {path.name}\n' for path in assets))
    rows = '\n'.join(f"| {TARGETS[flavor].minimum}+ | {', '.join(TARGETS[flavor].architectures)} | `{artifact_name(meta['version'], flavor)}` |" for flavor in RELEASE_FLAVORS)
    notes = f"""<!-- oshell-release:{meta['commit']} -->
OShell {meta['version']}（build {meta['build']}）

## 本次变更

{changes}

## 安装包

| 最低 macOS | 架构 | DMG |
| --- | --- | --- |
{rows}

Apple Silicon 包支持 macOS 13 及更新系统；Intel（x86_64 / amd64）包统一支持 macOS 10.13 及更新系统。
下载适合本机的一种 DMG，将 OShell.app 拖入 Applications。包内附带 SHA256SUMS.txt（包内文件校验）和 release-manifest.json（构建信息）；对应源码包单独提供。

这些安装包使用{signing_label}，未进行 Developer ID 签名或 Apple 公证。流水线校验架构、部署目标、载荷和签名完整性，并运行构建机原生架构的核心测试；不代表已在 macOS 10.13 的真实系统上完成验证。
{'内置更新直接使用上述 DMG，签名更新信息包含在本页中，无需额外 XML 或更新 ZIP。旧客户端请手动安装本版本一次。' if updates else '本次仅发布手动安装包，不包含内置更新信息。'}

对应提交：`{meta['commit']}`
"""
    (output/'RELEASE_NOTES.md').write_text(notes + '\n' + '\n'.join(updates) + '\n')
    return release_manifest

def gh(*args, check=True):
    return subprocess.run(['gh', *args], capture_output=True, text=True, check=check)

def verify_remote_tag(repository, tag, commit):
    ref = json.loads(gh('api', f'repos/{repository}/git/ref/tags/{tag}').stdout)['object']
    for _ in range(8):
        if ref['type'] == 'commit':
            if ref['sha'] != commit: raise ValueError('Remote tag moved after builds started')
            return
        if ref['type'] != 'tag': break
        ref = json.loads(gh('api', f"repos/{repository}/git/tags/{ref['sha']}").stdout)['object']
    raise ValueError('Cannot resolve release tag to its source commit')

def publish(meta, repository, output):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Repository must be owner/repo')
    internal = {'RELEASE_NOTES.md', 'release-manifest.json', 'SHA256SUMS.txt'}
    files = sorted(path for path in output.iterdir() if path.name not in internal)
    expected = {artifact_name(meta['version'], flavor) for flavor in RELEASE_FLAVORS} | {f"OShell-{meta['version']}-source.tar.gz"}
    manifest = json.loads((output/'release-manifest.json').read_text())
    aliases = manifest.get('compatibilityAliases', [])
    if aliases:
        name = f"OShell-{meta['version']}-macOS13-x86_64.dmg"
        source = artifact_name(meta['version'], 'legacy')
        expected_alias = dict(file=name, source=source, sha256=sha256(output/source), size=(output/source).stat().st_size)
        if aliases != [expected_alias] or (output/name).is_symlink() or sha256(output/name) != expected_alias['sha256']:
            raise ValueError('Compatibility alias must be identical to the verified Intel installer')
        expected.add(name)
    if {path.name for path in files} != expected:
        raise ValueError('Release asset set is incomplete')
    expected_checksums = expected | {'release-manifest.json'}
    checked = set()
    for line in (output/'SHA256SUMS.txt').read_text().splitlines():
        digest, name = line.split('  ', 1)
        if Path(name).name != name or name not in expected_checksums or name in checked or (output/name).is_symlink() or sha256(output/name) != digest:
            raise ValueError('Release checksum verification failed')
        checked.add(name)
    if checked != expected_checksums:
        raise ValueError('Release checksums do not cover every asset')
    verify_remote_tag(repository, meta['tag'], meta['commit'])
    existing = gh('release', 'view', meta['tag'], '--repo', repository, '--json', 'isDraft,body', check=False)
    marker = '<!-- oshell-release:' + meta['commit'] + ' -->'
    if existing.returncode == 0:
        value = json.loads(existing.stdout)
        if not value['isDraft'] or marker not in value.get('body', ''):
            raise ValueError('Refusing to modify a published Release or a draft not created for this commit')
    elif 'release not found' in existing.stderr.lower() or 'HTTP 404' in existing.stderr:
        gh('release', 'create', meta['tag'], '--repo', repository, '--verify-tag', '--target', meta['commit'], '--draft', '--title', 'OShell ' + meta['version'], '--notes-file', str(output/'RELEASE_NOTES.md'))
    else:
        raise RuntimeError(existing.stderr)
    # --clobber is used only for an unpublished draft owned by this workflow/commit.
    gh('release', 'edit', meta['tag'], '--repo', repository, '--notes-file', str(output/'RELEASE_NOTES.md'))
    gh('release', 'upload', meta['tag'], *map(str, files), '--repo', repository, '--clobber')
    published = json.loads(gh('release', 'view', meta['tag'], '--repo', repository, '--json', 'assets,body').stdout)
    if published.get('body') != (output/'RELEASE_NOTES.md').read_text(): raise ValueError('Remote signed update metadata changed; Release remains a draft')
    assets = published['assets']
    remote = {asset['name']: asset['size'] for asset in assets}
    if remote != {path.name: path.stat().st_size for path in files}:
        raise ValueError('Incomplete remote assets; Release remains a draft')
    verify_remote_tag(repository, meta['tag'], meta['commit'])
    gh('release', 'edit', meta['tag'], '--repo', repository, '--draft=false', '--latest')
    print('Published', meta['tag'], 'with two verified DMGs and corresponding source')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['prepare', 'metadata', 'stage', 'collect', 'publish'])
    parser.add_argument('--tag', required=True)
    parser.add_argument('--commit')
    parser.add_argument('--build-only', action='store_true', help='Validate the selected source for metadata/stage without changing tags or publishing')
    parser.add_argument('--github-output', type=Path)
    parser.add_argument('--flavor', choices=RELEASE_FLAVORS)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--artifacts', type=Path)
    parser.add_argument('--updates-artifacts', type=Path)
    parser.add_argument('--source', type=Path)
    parser.add_argument('--repository', default=os.environ.get('GITHUB_REPOSITORY', ''))
    args = parser.parse_args()
    if args.build_only and args.command not in ['metadata', 'stage']: parser.error('--build-only is only valid for metadata/stage')
    meta = prepare(args.tag, args.repository) if args.command == 'prepare' else metadata(args.tag, args.commit, build_only=args.build_only)
    if args.command in ['prepare', 'metadata']:
        if args.github_output:
            with args.github_output.open('a') as stream:
                stream.write(''.join(f'{key}={value}\n' for key, value in meta.items()))
        print(json.dumps(meta, indent=2))
    elif args.command == 'stage':
        if not args.flavor or not args.output: parser.error('stage needs --flavor and --output')
        stage(meta, args.flavor, args.output)
    elif args.command == 'collect':
        if not args.artifacts or not args.source or not args.output: parser.error('collect needs --artifacts, --source and --output')
        collect(meta, args.artifacts, args.source, args.output, args.updates_artifacts, args.repository)
    else:
        if not args.output or not args.repository: parser.error('publish needs --output and --repository')
        publish(meta, args.repository, args.output)

if __name__ == '__main__':
    main()
