# SPDX-License-Identifier: GPL-3.0-only
"""One immutable handoff for pre-0.4.1 clients; never a legacy build target catalog."""
import base64
import copy
import hashlib
import json
import re
import xml.etree.ElementTree as ET
from release_targets import ReleaseTarget

VERSION = '0.4.1'
BUILD = '105'
FINAL_BUILD = '106'
# Historical wire identifiers only. All aliases reuse one of two bridge binaries.
CHANNELS = {
    'macOS13-arm64': ('arm64', '13.0'),
    'macOS10.13-Intel': ('legacy', '10.13'),
    'macOS15-arm64': ('arm64', '15.0'),
    'macOS15-amd64': ('legacy', '15.0'),
    'macOS13-x86_64': ('legacy', '13.0'),
}
REPOSITORIES = ('oshell-desktop/oshell', 'arnolixi/oshell')
NS = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
ET.register_namespace('sparkle', NS[1:-1])

def load_config(path):
    value = json.loads(path.read_text())
    if value.get('format') != 'OShell.upgrade-bridge.v1' or value.get('version') != VERSION or value.get('build') != BUILD or not re.fullmatch('[a-f0-9]{40}', value.get('commit', '')):
        raise ValueError('Invalid pinned bridge configuration')
    return value

def filename(suffix): return f'OShell-{VERSION}-{suffix}.dmg'
def source_filename(): return f'OShell-{VERSION}-bridge-source.tar.gz'
def asset_names(): return {filename(suffix) for suffix in CHANNELS} | {source_filename()}
def marker(repository): return '<!-- oshell-migration-v1:' + repository + ':'

def targets():
    return {suffix: ReleaseTarget(('arm64' if flavor == 'arm64' else 'x86_64',), minimum, suffix)
            for suffix, (flavor, minimum) in CHANNELS.items()}

def signed_feed(encoded, key, repository, suffix):
    tree = ET.fromstring(base64.b64decode(encoded, validate=True))
    item = tree.find('./channel/item')
    item.find(NS+'version').text = BUILD
    item.find(NS+'shortVersionString').text = VERSION
    item.find(NS+'minimumSystemVersion').text = CHANNELS[suffix][1]
    description = item.find('description')
    if description is None: description = ET.SubElement(item, 'description')
    description.text = '这是一次性升级过渡版（build 105）。安装并重新启动后，macOS 15+ 会继续检查 OShell 0.4.1 正式版（build 106）；请完成第二步应用内更新。现有配置保留，低于 macOS 15 的系统不会安装正式版。'
    item.find('enclosure').set('url', f'https://github.com/{repository}/releases/download/v{VERSION}/{filename(suffix)}')
    data = ET.tostring(tree, encoding='utf-8', xml_declaration=True)
    trailer = f'<!-- sparkle-signatures:\nedSignature: {base64.b64encode(key.sign(data)).decode()}\nlength: {len(data)}\n-->\n'.encode()
    return base64.b64encode(data+trailer).decode()

def marker_text(repository, feeds):
    payload = base64.b64encode(json.dumps(feeds, sort_keys=True, separators=(',', ':')).encode()).decode()
    return marker(repository) + payload + ' -->'

def document(release, repository, public_key, pages):
    if repository not in REPOSITORIES or release.get('tag_name') != 'v'+VERSION:
        raise ValueError('Migration must come from the pinned 0.4.1 release and repository')
    matches = re.findall(re.escape(marker(repository))+r'([A-Za-z0-9+/=]+) -->', release.get('body', ''))
    if len(matches) != 1: raise ValueError('Missing or duplicate migration metadata')
    encoded = base64.b64decode(matches[0], validate=True)
    if len(encoded) > 200000: raise ValueError('Migration metadata exceeds size limit')
    feeds = json.loads(encoded)
    if set(feeds) != set(CHANNELS): raise ValueError('Unexpected migration channels')
    proxy = copy.deepcopy(release)
    proxy['body'] = '\n'.join('<!-- oshell-update-v1:'+s+':'+f+' -->' for s,f in feeds.items())
    for asset in proxy.get('assets', []):
        # Only repository transfer aliases are allowed, not arbitrary download hosts.
        url = asset.get('browser_download_url', '')
        expected = f'https://github.com/{REPOSITORIES[0]}/releases/download/v{VERSION}/{asset["name"]}'
        if url != expected: raise ValueError('Migration asset has an untrusted source URL')
        asset['browser_download_url'] = f'https://github.com/{repository}/releases/download/v{VERSION}/{asset["name"]}'
    value = pages.document(proxy, repository, public_key, flavors=CHANNELS, targets=targets())
    if value['build'] != BUILD: raise ValueError('Migration build must remain frozen')
    return value

def validate_manifest(manifest, meta, directory):
    migration = manifest.get('oneTimeMigration')
    if migration is None: return set()
    if meta['version'] != VERSION or meta['build'] != FINAL_BUILD or migration.get('build') != BUILD:
        raise ValueError('Unexpected one-time migration version')
    if not re.fullmatch('[a-f0-9]{40}', migration.get('commit', '')):
        raise ValueError('Missing audited bridge source commit')
    records = migration.get('files', [])
    if len(records) != len(asset_names()) or {r['file'] for r in records} != asset_names():
        raise ValueError('Unexpected migration assets')
    for record in records:
        path = directory/record['file']
        if path.is_symlink() or not path.is_file() or path.stat().st_size != record['size'] or hashlib.sha256(path.read_bytes()).hexdigest() != record['sha256']:
            raise ValueError('Migration asset integrity check failed')
    return asset_names()
