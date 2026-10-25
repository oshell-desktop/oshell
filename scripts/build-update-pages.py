#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Publishable static metadata from a complete public Release; no private signing key needed."""
import argparse, base64, html, json, plistlib, re
from pathlib import Path
import xml.etree.ElementTree as ET
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from release_targets import TARGETS, RELEASE_FLAVORS

ROOT = Path(__file__).resolve().parent.parent
NS = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'

def document(release, repository, public_key, flavors=None):
    if not re.fullmatch(r'[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*/[A-Za-z0-9_.-]+', repository) or repository.split('/')[-1] in ('.', '..'):
        raise ValueError('Invalid repository')
    tag = release.get('tag_name', '')
    if release.get('draft') is not False or release.get('prerelease') is not False or not re.fullmatch(r'v\d+\.\d+\.\d+', tag):
        raise ValueError('A published stable Release is required')
    key = Ed25519PublicKey.from_public_bytes(base64.b64decode(public_key, validate=True))
    platforms, builds = {}, set()
    if flavors is None:
        flavors = list(RELEASE_FLAVORS)
        # Read aliases already present in historical Releases. New releases
        # publish only RELEASE_FLAVORS and never synthesize an alias here.
        if '<!-- oshell-update-v1:macOS13-x86_64:' in release.get('body', ''):
            flavors.append('intel')
    for flavor in flavors:
        target = TARGETS[flavor]
        matches = re.findall(r'<!-- oshell-update-v1:' + re.escape(target.suffix) + r':([A-Za-z0-9+/=]+) -->', release.get('body', ''))
        if len(matches) != 1: raise ValueError('Exactly one signed feed per platform is required')
        signed = base64.b64decode(matches[0], validate=True)
        marker = signed.rfind(b'<!-- sparkle-signatures:')
        if len(signed) > 32768 or marker < 1: raise ValueError('Missing signed feed trailer')
        trailer = re.fullmatch(rb'<!-- sparkle-signatures:\s*edSignature: ([A-Za-z0-9+/=]+)\s*length: ([0-9]+)\s*-->\s*', signed[marker:])
        if not trailer or int(trailer[2]) != marker: raise ValueError('Invalid signed feed length')
        key.verify(base64.b64decode(trailer[1], validate=True), signed[:marker])
        if b'<!DOCTYPE' in signed.upper() or b'<!ENTITY' in signed.upper(): raise ValueError('External XML entities are forbidden')
        items = ET.fromstring(signed).findall('./channel/item')
        if len(items) != 1: raise ValueError('Expected one update item')
        item = items[0]; build = item.findtext(NS + 'version', '')
        if not re.fullmatch(r'[1-9][0-9]{0,17}', build) or item.findtext(NS + 'shortVersionString') != tag[1:] or item.findtext(NS + 'minimumSystemVersion') != target.minimum:
            raise ValueError('Signed version/platform mismatch')
        builds.add(build)
        enclosures = item.findall('enclosure')
        name = f'OShell-{tag[1:]}-{target.suffix}.dmg'
        url = f'https://github.com/{repository}/releases/download/{tag}/{name}'
        if len(enclosures) != 1: raise ValueError('Expected one installer')
        enclosure = enclosures[0]
        assets = [a for a in release.get('assets', []) if a.get('name') == name]
        if len(assets) != 1 or assets[0].get('state') != 'uploaded' or assets[0].get('browser_download_url') != url:
            raise ValueError('Missing or incomplete Release asset')
        size = assets[0].get('size')
        if type(size) is not int or size <= 0 or enclosure.get('url') != url or enclosure.get('length') != str(size) or len(base64.b64decode(enclosure.get(NS + 'edSignature', ''), validate=True)) != 64:
            raise ValueError('Installer differs from signed metadata')
        platforms[target.suffix] = dict(file=name, size=size, signedFeed=matches[0])
    if len(builds) != 1: raise ValueError('Mixed build numbers')
    return dict(format='OShell.static-updates.v1', repository=repository, version=tag[1:], build=builds.pop(), platforms=platforms)

def write_site(value, output):
    if output.exists() and any(output.iterdir()): raise ValueError('Pages output must be empty')
    (output/'updates').mkdir(parents=True, exist_ok=True)
    (output/'updates/latest.json').write_text(json.dumps(value, indent=2) + '\n')
    (output/'.nojekyll').write_text('')
    repo = html.escape(value['repository'], quote=True); version = html.escape(value['version'])
    links = ''.join(f'<li><a href="https://github.com/{repo}/releases/download/v{version}/{html.escape(item["file"], quote=True)}">{html.escape(platform)}</a></li>' for platform,item in value['platforms'].items())
    (output/'index.html').write_text(f'''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>OShell 更新服务</title><style>body{{font:16px system-ui;max-width:720px;margin:64px auto;padding:0 24px;line-height:1.7}}a{{color:#b74b15}}</style><h1>OShell 更新服务</h1><p>当前版本：{version}。此站点提供签名更新信息；安装包保存在 GitHub Releases。</p><ul>{links}</ul><p><a href="https://github.com/{repo}">项目主页</a> · <a href="updates/latest.json">更新信息</a></p></html>\n''')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release', type=Path, required=True); parser.add_argument('--repository', required=True)
    parser.add_argument('--output', type=Path, required=True); parser.add_argument('--info', type=Path, default=ROOT/'scripts/Info.plist')
    args = parser.parse_args()
    value = document(json.loads(args.release.read_text()), args.repository, plistlib.loads(args.info.read_bytes())['SUPublicEDKey'])
    write_site(value, args.output)
    print('Verified and generated static update site:', value['version'], 'build', value['build'], 'platforms', len(value['platforms']))
if __name__ == '__main__': main()
