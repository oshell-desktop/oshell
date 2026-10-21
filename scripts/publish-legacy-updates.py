#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Keep the transferred repository's original Pages clients updating securely."""
import argparse
import base64
import copy
import hashlib
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
FLAVORS = ('legacy', 'arm64', 'intel')
NS = PAGES.NS
ET.register_namespace('sparkle', NS[1:-1])
NOTICE = ('旧更新仓库 `arnolixi/oshell` 继续有效。旧名称的 `macOS13-x86_64.dmg` '
          '是 macOS 10.13 Intel 包的同内容兼容副本，不是第三个编译目标。')


def signed_xml(encoded, key, *, url, minimum):
    tree = ET.fromstring(base64.b64decode(encoded, validate=True))
    tree.find('./channel/item/enclosure').set('url', url)
    tree.find('./channel/item/'+NS+'minimumSystemVersion').text = minimum
    data = ET.tostring(tree, encoding='utf-8', xml_declaration=True)
    signature = base64.b64encode(key.sign(data)).decode()
    return base64.b64encode(data + f'<!-- sparkle-signatures:\nedSignature: {signature}\nlength: {len(data)}\n-->\n'.encode()).decode()


def prepare(release, public, key):
    actual = base64.b64encode(key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()
    if actual != public: raise ValueError('Signing key differs from the pinned update public key')
    original = PAGES.document(release, CURRENT, public)
    value = copy.deepcopy(release)
    value['body'] = value['body'].replace(
        '旧版现代 Intel 客户端需手动安装一次 Intel 兼容包，之后使用统一更新通道',
        '旧版现代 Intel 客户端可通过旧名称兼容附件直接升级，之后使用统一更新通道')
    value['body'] = value['body'].replace('旧客户端请手动安装本版本一次。', '使用 Pages 更新的旧客户端可通过兼容入口直接升级。')
    base = original['platforms']['macOS10.13-Intel']
    alias = f'OShell-{original["version"]}-macOS13-x86_64.dmg'
    alias_url = f'https://github.com/{CURRENT}/releases/download/{release["tag_name"]}/{alias}'
    feed = signed_xml(base['signedFeed'], key, url=alias_url, minimum='13.0')
    marker = '<!-- oshell-update-v1:macOS13-x86_64:' + feed + ' -->'
    pattern = r'<!-- oshell-update-v1:macOS13-x86_64:[A-Za-z0-9+/=]+ -->'
    if re.search(pattern, value['body']): value['body'] = re.sub(pattern, marker, value['body'])
    else: value['body'] += '\n' + marker + '\n'
    if NOTICE not in value['body']: value['body'] += '\n' + NOTICE + '\n'
    value['assets'] = [a for a in value['assets'] if a['name'] != alias]
    value['assets'].append(dict(name=alias, size=base['size'], state='uploaded', browser_download_url=alias_url))
    current = PAGES.document(value, CURRENT, public)
    old = copy.deepcopy(value)
    old['body'] = ''
    for flavor in FLAVORS:
        target = PAGES.TARGETS[flavor]; platform = current['platforms'][target.suffix]
        url = f'https://github.com/{LEGACY}/releases/download/{release["tag_name"]}/{platform["file"]}'
        encoded = signed_xml(platform['signedFeed'], key, url=url, minimum=target.minimum)
        old['body'] += '<!-- oshell-update-v1:' + target.suffix + ':' + encoded + ' -->\n'
    for asset in old['assets']:
        asset['browser_download_url'] = asset['browser_download_url'].replace('/'+CURRENT+'/', '/'+LEGACY+'/')
    legacy = PAGES.document(old, LEGACY, public, flavors=FLAVORS)
    return value['body'], current, legacy


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
    body,current,legacy = prepare(release,public,key)
    base = current['platforms']['macOS10.13-Intel']; alias = current['platforms']['macOS13-x86_64']
    data = (output/base['file']).read_bytes()
    item = ET.fromstring(base64.b64decode(base['signedFeed'])).find('./channel/item/enclosure')
    key.public_key().verify(base64.b64decode(item.get(NS+'edSignature'),validate=True),data)
    if len(data) != base['size']: raise ValueError('Installer size mismatch')
    target = output/alias['file']
    if target.exists() and (target.is_symlink() or target.read_bytes() != data): raise ValueError('Existing alias differs from the verified installer')
    target.write_bytes(data)
    (output/'RELEASE_NOTES.md').write_text(body)
    manifest['compatibilityAliases'] = [dict(file=target.name,source=base['file'],sha256=hashlib.sha256(data).hexdigest(),size=len(data))]
    manifest_path.write_text(json.dumps(manifest,indent=2)+'\n')
    files = sorted(p for p in output.iterdir() if p.name not in ('SHA256SUMS.txt','RELEASE_NOTES.md'))
    (output/'SHA256SUMS.txt').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in files))
    return current,legacy


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--private-key', type=Path)
    parser.add_argument('--release-output',type=Path,help='Prepare the compatibility alias BEFORE publishing an immutable Release')
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
        if release['tag_name'] != args.tag: raise ValueError('Only Latest may update compatibility Pages')
        flavors = [f for f in ('legacy','arm64','intel','compat') if '<!-- oshell-update-v1:'+PAGES.TARGETS[f].suffix+':' in release['body']]
        if not {'legacy','arm64'}.issubset(flavors): raise ValueError('Release is missing a required installer')
        current = PAGES.document(release,CURRENT,public,flavors=flavors)
        legacy = legacy_document(release,current,public,key)
        if 'intel' not in flavors: print('This immutable release has no modern Intel filename alias; that client requires the next compatibility-enabled release.')
    PAGES.write_site(current,args.output/'current')
    PAGES.write_site(legacy,args.output/'legacy')
    print('Prepared signed current and legacy update sites for',args.tag,'; no installer compilation performed.')


if __name__ == '__main__': main()
