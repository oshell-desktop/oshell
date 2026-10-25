#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Keep the transferred repository's original Pages clients updating securely."""
import argparse
import base64
import copy
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location('update_pages', ROOT/'scripts/build-update-pages.py')
PAGES = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(PAGES)
CURRENT = 'oshell-desktop/oshell'
LEGACY = 'arnolixi/oshell'
FLAVORS = PAGES.RELEASE_FLAVORS
NS = PAGES.NS
ET.register_namespace('sparkle', NS[1:-1])


def signed_xml(encoded, key, *, url, minimum):
    tree = ET.fromstring(base64.b64decode(encoded, validate=True))
    tree.find('./channel/item/enclosure').set('url', url)
    tree.find('./channel/item/'+NS+'minimumSystemVersion').text = minimum
    data = ET.tostring(tree, encoding='utf-8', xml_declaration=True)
    signature = base64.b64encode(key.sign(data)).decode()
    return base64.b64encode(data + f'<!-- sparkle-signatures:\nedSignature: {signature}\nlength: {len(data)}\n-->\n'.encode()).decode()


def prepare(release, public, key, *, flavors=FLAVORS):
    actual = base64.b64encode(key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()
    if actual != public: raise ValueError('Signing key differs from the pinned update public key')
    current = PAGES.document(release, CURRENT, public, flavors=flavors)
    return release['body'], current, legacy_document(release, current, public, key)


def gh(*args):
    return subprocess.check_output(['gh', *args], text=True)


def legacy_document(release, current, public, key):
    old = copy.deepcopy(release); old['body'] = ''
    flavors = []
    for flavor in ('legacy', 'arm64', 'intel', 'compat'):
        target = PAGES.TARGETS[flavor]
        if target.suffix not in current['platforms']: continue
        flavors.append(flavor)
        platform = current['platforms'][target.suffix]
        url = f'https://github.com/{LEGACY}/releases/download/{release["tag_name"]}/{platform["file"]}'
        encoded = signed_xml(platform['signedFeed'], key, url=url, minimum=target.minimum)
        old['body'] += '<!-- oshell-update-v1:' + target.suffix + ':' + encoded + ' -->\n'
    for asset in old['assets']:
        asset['browser_download_url'] = asset['browser_download_url'].replace('/'+CURRENT+'/', '/'+LEGACY+'/')
    return PAGES.document(old, LEGACY, public, flavors=flavors)


def prepare_local(output, tag, public, key):
    manifest_path = output/'release-manifest.json'
    manifest = json.loads(manifest_path.read_text())
    if manifest['tag'] != tag: raise ValueError('Release tag mismatch')
    release = dict(tag_name=tag,draft=False,prerelease=False,body=(output/'RELEASE_NOTES.md').read_text(),assets=[])
    for path in output.glob('*.dmg'):
        if path.is_symlink(): raise ValueError('Installer must not be a symlink')
        release['assets'].append(dict(name=path.name,size=path.stat().st_size,state='uploaded',browser_download_url=f'https://github.com/{CURRENT}/releases/download/{tag}/{path.name}'))
    expected = {f'OShell-{tag[1:]}-{PAGES.TARGETS[flavor].suffix}.dmg' for flavor in FLAVORS}
    if {asset['name'] for asset in release['assets']} != expected or manifest.get('compatibilityAliases'):
        raise ValueError('Future releases must contain exactly two DMGs; filename aliases are not allowed')
    markers = set(re.findall(r'<!-- oshell-update-v1:([^:]+):', release['body']))
    if markers != {PAGES.TARGETS[flavor].suffix for flavor in FLAVORS}:
        raise ValueError('Future releases require signed metadata for exactly two DMGs')
    _,current,legacy = prepare(release,public,key)
    # Verify both existing artifacts, but never alter release notes, manifests,
    # checksums or installers. Only the separate Pages output may be generated.
    for platform in current['platforms'].values():
        data = (output/platform['file']).read_bytes()
        item = ET.fromstring(base64.b64decode(platform['signedFeed'])).find('./channel/item/enclosure')
        key.public_key().verify(base64.b64decode(item.get(NS+'edSignature'),validate=True),data)
        if len(data) != platform['size']: raise ValueError('Installer size mismatch')
    return current,legacy


def prepare_existing(release, tag, public, key):
    # An existing Release may contain historical aliases. Preserve its actual
    # signed platforms in Pages without creating or changing any Release asset.
    if release['tag_name'] != tag: raise ValueError('Only Latest may update compatibility Pages')
    flavors = [f for f in ('legacy','arm64','intel','compat') if '<!-- oshell-update-v1:'+PAGES.TARGETS[f].suffix+':' in release['body']]
    if not set(FLAVORS).issubset(flavors): raise ValueError('Release is missing a required installer')
    _,current,legacy = prepare(release,public,key,flavors=flavors)
    return current,legacy


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--private-key', type=Path)
    parser.add_argument('--release-output',type=Path,help='Read and verify the two staged DMGs; generate Pages only without modifying release files')
    args = parser.parse_args()
    if args.output.exists(): raise ValueError('Choose a new output directory')
    if args.private_key:
        if args.private_key.is_symlink() or args.private_key.stat().st_mode & 0o077: raise ValueError('Key file must be private (0600)')
        secret = args.private_key.read_bytes().strip()
    else: secret = os.environ.pop('OSHELL_UPDATE_SIGNING_KEY', '').strip().encode()
    key = Ed25519PrivateKey.from_private_bytes(base64.b64decode(secret, validate=True))
    public = plistlib.loads((ROOT/'scripts/Info.plist').read_bytes())['SUPublicEDKey']
    actual = base64.b64encode(key.public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw)).decode()
    if actual != public: raise ValueError('Signing key differs from the pinned update public key')
    if args.release_output:
        current,legacy = prepare_local(args.release_output,args.tag,public,key)
    else:
        # Existing releases may be immutable: only regenerate metadata, never
        # mutate their assets, notes, tags or original signed feeds.
        release = json.loads(gh('api',f'repos/{CURRENT}/releases/latest'))
        current,legacy = prepare_existing(release,args.tag,public,key)
        if 'macOS13-x86_64' not in current['platforms']:
            print('Old Intel clients requiring the retired filename must install the macOS 10.13 Intel package manually once.')
    PAGES.write_site(current,args.output/'current')
    PAGES.write_site(legacy,args.output/'legacy')
    print('Prepared signed current and legacy update sites for',args.tag,'; no installer compilation performed.')


if __name__ == '__main__': main()
