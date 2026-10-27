#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Offline signed-feed/site tests. Keys are ephemeral fixtures, never production credentials."""
import base64, copy, importlib.util, json, tempfile, unittest
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
from release_targets import TARGETS, RELEASE_FLAVORS

spec = importlib.util.spec_from_file_location('pages', Path(__file__).with_name('build-update-pages.py'))
PAGES = importlib.util.module_from_spec(spec); spec.loader.exec_module(PAGES)

class PagesTests(unittest.TestCase):
    def setUp(self):
        key = Ed25519PrivateKey.generate()
        self.public = base64.b64encode(key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()
        self.release = dict(draft=False, prerelease=False, tag_name='v1.2.3', body='', assets=[])
        for flavor in RELEASE_FLAVORS:
            target = TARGETS[flavor]; name = f'OShell-1.2.3-{target.suffix}.dmg'
            url = 'https://github.com/example/OShell/releases/download/v1.2.3/' + name
            xml = f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>45</sparkle:version><sparkle:shortVersionString>1.2.3</sparkle:shortVersionString><sparkle:minimumSystemVersion>{target.minimum}</sparkle:minimumSystemVersion><enclosure url="{url}" length="1234" sparkle:edSignature="{base64.b64encode(bytes(64)).decode()}"/></item></channel></rss>'.encode()
            signed = xml + f'<!-- sparkle-signatures:\nedSignature: {base64.b64encode(key.sign(xml)).decode()}\nlength: {len(xml)}\n-->\n'.encode()
            self.release['body'] += f'<!-- oshell-update-v1:{target.suffix}:{base64.b64encode(signed).decode()} -->\n'
            self.release['assets'].append(dict(name=name, size=1234, state='uploaded', browser_download_url=url))
    def generate(self, release=None): return PAGES.document(release or self.release, 'example/OShell', self.public)
    def test_complete_signed_release(self):
        value = self.generate()
        self.assertEqual(value['build'], '45'); self.assertEqual(len(value['platforms']), 2)
        for suffix,platform in value['platforms'].items():
            self.assertIn(f':{suffix}:{platform["signedFeed"]} -->', self.release['body'])
    def test_publication_failure_never_writes_site(self):
        for field in ['draft', 'prerelease']:
            value = copy.deepcopy(self.release); value[field] = True
            with self.assertRaises(ValueError): self.generate(value)
    def test_missing_or_duplicate_assets_rejected(self):
        for mutate in [lambda r: r['assets'].pop(), lambda r: r['assets'].append(r['assets'][0])]:
            value = copy.deepcopy(self.release); mutate(value)
            with self.assertRaises(ValueError): self.generate(value)
    def test_signed_size_and_repository_bound(self):
        for field,content in [('size', 1235), ('state', 'new'), ('browser_download_url', 'https://invalid.example/other.dmg')]:
            value = copy.deepcopy(self.release); value['assets'][0][field] = content
            with self.assertRaises(ValueError): self.generate(value)
    def test_signature_tampering_rejected(self):
        value = copy.deepcopy(self.release)
        encoded = value['body'].split(':', 2)[2].split(' -->', 1)[0]
        tampered = base64.b64decode(encoded).replace(b'<sparkle:version>45', b'<sparkle:version>46')
        value['body'] = value['body'].replace(encoded, base64.b64encode(tampered).decode())
        with self.assertRaises(Exception): self.generate(value)
    def test_wrong_signing_key_rejected(self):
        self.public = base64.b64encode(bytes(32)).decode()
        with self.assertRaises(Exception): self.generate()
    def test_missing_or_duplicate_platform_rejected(self):
        for body in ['', self.release['body'] + self.release['body']]:
            value = copy.deepcopy(self.release); value['body'] = body
            with self.assertRaises(ValueError): self.generate(value)
    def test_site_contains_no_installers_or_source(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)/'site'; value = self.generate(); PAGES.write_site(value, root)
            self.assertEqual({str(p.relative_to(root)) for p in root.rglob('*') if p.is_file()}, {'index.html', '.nojekyll', 'updates/latest.json', 'updates/macos15.json'})
            self.assertEqual(json.loads((root/'updates/latest.json').read_text()), value)
            with self.assertRaises(ValueError): PAGES.write_site(value, root)
    def test_deployment_runs_after_release_and_uploads_only_generated_files(self):
        root = Path(__file__).resolve().parents[1]
        workflow = (root/'.github/workflows/release.yml').read_text()
        self.assertIn('needs: [metadata, release]', workflow)
        deploy = (root/'.github/workflows/update-pages.yml').read_text()
        self.assertIn('path: work/update-site', deploy)
        self.assertNotIn('OSHELL_UPDATE_SIGNING_KEY', deploy)
        self.assertIn('pages: write', deploy); self.assertIn('cancel-in-progress: false', deploy)
if __name__ == '__main__': unittest.main()
