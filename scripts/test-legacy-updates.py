#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
import base64
import copy
import importlib.util
import json
import tempfile
import hashlib
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

spec = importlib.util.spec_from_file_location('legacy',Path(__file__).with_name('publish-legacy-updates.py'))
LEGACY = importlib.util.module_from_spec(spec); spec.loader.exec_module(LEGACY)


class CompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.key = Ed25519PrivateKey.generate()
        self.public = base64.b64encode(self.key.public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw)).decode()
        self.release = dict(draft=False,prerelease=False,tag_name='v1.2.3',body='Original release notes\n',assets=[])
        for flavor in ['legacy','arm64']:
            target = LEGACY.PAGES.TARGETS[flavor]
            name = f'OShell-1.2.3-{target.suffix}.dmg'
            url = f'https://github.com/{LEGACY.CURRENT}/releases/download/v1.2.3/{name}'
            archive = b'synthetic installer '+flavor.encode()
            signature = base64.b64encode(self.key.sign(archive)).decode()
            xml = f'<rss xmlns:sparkle="{LEGACY.NS[1:-1]}"><channel><item><sparkle:version>83</sparkle:version><sparkle:shortVersionString>1.2.3</sparkle:shortVersionString><sparkle:minimumSystemVersion>{target.minimum}</sparkle:minimumSystemVersion><enclosure url="{url}" length="{len(archive)}" sparkle:edSignature="{signature}"/></item></channel></rss>'.encode()
            encoded = LEGACY.signed_xml(base64.b64encode(xml).decode(),self.key,url=url,minimum=target.minimum)
            self.release['body'] += '<!-- oshell-update-v1:'+target.suffix+':'+encoded+' -->\n'
            self.release['assets'].append(dict(name=name,state='uploaded',size=len(archive),browser_download_url=url))

    def prepare(self): return LEGACY.prepare(self.release,self.public,self.key)

    def test_both_repositories_accept_all_supported_client_flavors(self):
        original = copy.deepcopy(self.release)
        body,current,old = self.prepare()
        self.assertEqual(self.release,original)
        for site,repo in [(current,LEGACY.CURRENT),(old,LEGACY.LEGACY)]:
            self.assertEqual(site['repository'],repo)
            self.assertEqual(set(site['platforms']),{'macOS10.13-Intel','macOS13-arm64','macOS13-x86_64'})
            for name,platform in site['platforms'].items():
                xml=ET.fromstring(base64.b64decode(platform['signedFeed']))
                url=xml.find('./channel/item/enclosure').get('url')
                self.assertIn('/'+repo+'/releases/download/v1.2.3/',url)
                self.assertTrue(url.endswith('-'+name+'.dmg'))
        self.assertTrue(body.startswith(original['body']))

    def test_alias_preserves_installer_signature_and_size(self):
        _,site,_=self.prepare()
        base=site['platforms']['macOS10.13-Intel'];alias=site['platforms']['macOS13-x86_64']
        a=ET.fromstring(base64.b64decode(base['signedFeed'])).find('./channel/item')
        b=ET.fromstring(base64.b64decode(alias['signedFeed'])).find('./channel/item')
        self.assertEqual(base['size'],alias['size'])
        self.assertEqual(a.find('enclosure').get(LEGACY.NS+'edSignature'),b.find('enclosure').get(LEGACY.NS+'edSignature'))
        self.assertEqual(a.findtext(LEGACY.NS+'minimumSystemVersion'),'10.13')
        self.assertEqual(b.findtext(LEGACY.NS+'minimumSystemVersion'),'13.0')

    def test_published_alias_is_idempotent(self):
        body,site,old=self.prepare(); self.release['body']=body
        platform=site['platforms']['macOS13-x86_64']
        self.release['assets'].append(dict(name=platform['file'],size=platform['size'],state='uploaded',browser_download_url=f'https://github.com/{LEGACY.CURRENT}/releases/download/v1.2.3/'+platform['file']))
        self.assertEqual(self.prepare(),(body,site,old))

    def test_alias_prepared_before_immutable_release_publication(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            (root/'release-manifest.json').write_text(json.dumps(dict(tag='v1.2.3')))
            (root/'RELEASE_NOTES.md').write_text(self.release['body'])
            for flavor in ['legacy','arm64']:
                suffix=LEGACY.PAGES.TARGETS[flavor].suffix
                (root/f'OShell-1.2.3-{suffix}.dmg').write_bytes(b'synthetic installer '+flavor.encode())
            current,old=LEGACY.prepare_local(root,'v1.2.3',self.public,self.key)
            aliases=json.loads((root/'release-manifest.json').read_text())['compatibilityAliases']
            self.assertEqual(len(aliases),1)
            self.assertEqual((root/aliases[0]['file']).read_bytes(),(root/aliases[0]['source']).read_bytes())
            for line in (root/'SHA256SUMS.txt').read_text().splitlines():
                digest,name=line.split('  ')
                self.assertEqual(hashlib.sha256((root/name).read_bytes()).hexdigest(),digest)
            self.assertEqual(len(current['platforms']),3)
            self.assertEqual(old['repository'],'arnolixi/oshell')

    def test_wrong_key_rejected(self):
        with self.assertRaises(ValueError): LEGACY.prepare(self.release,self.public,Ed25519PrivateKey.generate())

    def test_untrusted_source_repository_rejected(self):
        self.release['assets'][0]['browser_download_url']='https://example.test/untrusted.dmg'
        with self.assertRaises(ValueError): self.prepare()

    def test_draft_or_missing_installers_rejected(self):
        self.release['draft']=True
        with self.assertRaises(ValueError): self.prepare()
        self.release['draft']=False;self.release['assets'].pop()
        with self.assertRaises(ValueError): self.prepare()

    def test_tampered_signed_feed_rejected(self):
        start=self.release['body'].index('<!-- oshell-update-v1:')
        head=self.release['body'][start:].split(':',2)[2].split(' -->')[0]
        raw=base64.b64decode(head).replace(b'version>83',b'version>84')
        self.release['body']=self.release['body'].replace(head,base64.b64encode(raw).decode())
        with self.assertRaises(Exception): self.prepare()

    def test_no_extra_compilation_job(self):
        from release_targets import RELEASE_FLAVORS
        self.assertEqual(RELEASE_FLAVORS,('legacy','arm64'))
        workflow=Path(__file__).resolve().parents[1]/'.github/workflows/repair-update-compatibility.yml'
        self.assertNotIn('package-release.py',workflow.read_text())
        self.assertNotIn('macos-',workflow.read_text())


if __name__=='__main__': unittest.main()
