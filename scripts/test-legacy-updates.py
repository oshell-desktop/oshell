#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
import base64
import copy
import importlib.util
import json
import tempfile
import hashlib
import subprocess
from pathlib import Path
import unittest
from unittest.mock import patch
import plistlib
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

    def add_historical_alias(self):
        # Only a fixture for releases already published by the old workflow.
        platform = LEGACY.PAGES.document(self.release, LEGACY.CURRENT, self.public)['platforms']['macOS10.13-Intel']
        name = 'OShell-1.2.3-macOS13-x86_64.dmg'
        url = f'https://github.com/{LEGACY.CURRENT}/releases/download/v1.2.3/{name}'
        feed = LEGACY.signed_xml(platform['signedFeed'], self.key, url=url, minimum='13.0')
        self.release['body'] += '<!-- oshell-update-v1:macOS13-x86_64:' + feed + ' -->\n'
        self.release['assets'].append(dict(name=name, size=platform['size'], state='uploaded', browser_download_url=url))
        return feed

    def stage(self, root):
        (root/'release-manifest.json').write_text(json.dumps(dict(tag='v1.2.3')))
        (root/'RELEASE_NOTES.md').write_text(self.release['body'])
        for flavor in ['legacy','arm64']:
            suffix=LEGACY.PAGES.TARGETS[flavor].suffix
            (root/f'OShell-1.2.3-{suffix}.dmg').write_bytes(b'synthetic installer '+flavor.encode())
        (root/'OShell-1.2.3-source.tar.gz').write_bytes(b'synthetic source')
        files=sorted(p for p in root.iterdir() if p.name != 'RELEASE_NOTES.md')
        (root/'SHA256SUMS.txt').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in files))

    def snapshot(self, root): return {p.name:p.read_bytes() for p in root.iterdir() if p.is_file()}

    def test_new_releases_have_two_platforms_in_both_repositories(self):
        original = copy.deepcopy(self.release)
        body,current,old = self.prepare()
        self.assertEqual(self.release,original)
        self.assertEqual(body,original['body'])
        for site,repo in [(current,LEGACY.CURRENT),(old,LEGACY.LEGACY)]:
            self.assertEqual(site['repository'],repo)
            self.assertEqual(set(site['platforms']),{'macOS10.13-Intel','macOS13-arm64'})
            for name,platform in site['platforms'].items():
                xml=ET.fromstring(base64.b64decode(platform['signedFeed']))
                url=xml.find('./channel/item/enclosure').get('url')
                self.assertIn('/'+repo+'/releases/download/v1.2.3/',url)
                self.assertTrue(url.endswith('-'+name+'.dmg'))
        for suffix in current['platforms']:
            first=ET.fromstring(base64.b64decode(current['platforms'][suffix]['signedFeed'])).find('./channel/item')
            second=ET.fromstring(base64.b64decode(old['platforms'][suffix]['signedFeed'])).find('./channel/item')
            self.assertEqual(first.find('enclosure').get(LEGACY.NS+'edSignature'),second.find('enclosure').get(LEGACY.NS+'edSignature'))
            self.assertEqual(first.findtext(LEGACY.NS+'minimumSystemVersion'),second.findtext(LEGACY.NS+'minimumSystemVersion'))

    def test_preparing_pages_does_not_modify_staged_release(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);self.stage(root);before=self.snapshot(root)
            current,old=LEGACY.prepare_local(root,'v1.2.3',self.public,self.key)
            self.assertEqual(self.snapshot(root),before)
            self.assertEqual(len(list(root.glob('*.dmg'))),2)
            self.assertNotIn('compatibilityAliases',json.loads((root/'release-manifest.json').read_text()))
            self.assertEqual(len(current['platforms']),2)
            self.assertEqual(old['repository'],'arnolixi/oshell')
            self.assertEqual(LEGACY.prepare_local(root,'v1.2.3',self.public,self.key),(current,old))

    def test_extra_local_alias_rejected_without_deleting_any_files(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);self.stage(root)
            (root/'OShell-1.2.3-macOS13-x86_64.dmg').write_bytes(b'synthetic installer legacy')
            before=self.snapshot(root)
            with self.assertRaisesRegex(ValueError,'exactly two'): LEGACY.prepare_local(root,'v1.2.3',self.public,self.key)
            self.assertEqual(self.snapshot(root),before)

    def test_stale_alias_manifest_or_metadata_rejected(self):
        for kind in ['manifest','metadata']:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as folder:
                root=Path(folder);self.stage(root)
                if kind=='manifest':
                    (root/'release-manifest.json').write_text(json.dumps(dict(tag='v1.2.3',compatibilityAliases=[{'file':'old.dmg'}])))
                else:
                    with (root/'RELEASE_NOTES.md').open('a') as stream: stream.write('<!-- oshell-update-v1:macOS13-x86_64:c3ludGhldGlj -->')
                before=self.snapshot(root)
                with self.assertRaises(ValueError): LEGACY.prepare_local(root,'v1.2.3',self.public,self.key)
                self.assertEqual(self.snapshot(root),before)

    def test_both_local_installer_signatures_are_required(self):
        for flavor in ['legacy','arm64']:
            with self.subTest(flavor=flavor), tempfile.TemporaryDirectory() as folder:
                root=Path(folder);self.stage(root)
                path=root/f'OShell-1.2.3-{LEGACY.PAGES.TARGETS[flavor].suffix}.dmg'
                path.write_bytes(b'x'*len(path.read_bytes()))
                before=self.snapshot(root)
                with self.assertRaises(Exception): LEGACY.prepare_local(root,'v1.2.3',self.public,self.key)
                self.assertEqual(self.snapshot(root),before)

    def test_existing_release_with_alias_remains_readable_and_unchanged(self):
        feed=self.add_historical_alias();before=copy.deepcopy(self.release)
        current,old=LEGACY.prepare_existing(self.release,'v1.2.3',self.public,self.key)
        self.assertEqual(self.release,before)
        self.assertEqual(current['platforms']['macOS13-x86_64']['signedFeed'],feed)
        self.assertEqual(set(current['platforms']),set(old['platforms']))
        self.assertEqual(len(current['platforms']),3)
        self.assertEqual(LEGACY.PAGES.document(self.release,LEGACY.CURRENT,self.public),current)

    def test_existing_two_package_release_does_not_gain_an_alias(self):
        before=copy.deepcopy(self.release)
        current,old=LEGACY.prepare_existing(self.release,'v1.2.3',self.public,self.key)
        self.assertEqual(self.release,before)
        self.assertEqual(len(current['platforms']),2);self.assertEqual(len(old['platforms']),2)
        with self.assertRaisesRegex(ValueError,'Latest'): LEGACY.prepare_existing(self.release,'v9.9.9',self.public,self.key)

    def test_repair_cli_only_reads_release_and_writes_local_sites(self):
        for historical in [False,True]:
            with self.subTest(historical=historical),tempfile.TemporaryDirectory() as folder:
                if historical:self.add_historical_alias()
                before=copy.deepcopy(self.release)
                root=Path(folder);(root/'scripts').mkdir()
                (root/'scripts/Info.plist').write_bytes(plistlib.dumps({'SUPublicEDKey':self.public}))
                key=root/'signing.key';key.touch(mode=0o600)
                key.write_bytes(base64.b64encode(self.key.private_bytes(serialization.Encoding.Raw,serialization.PrivateFormat.Raw,serialization.NoEncryption())))
                output=root/'sites'
                argv=['publish-legacy-updates.py','--tag','v1.2.3','--output',str(output),'--private-key',str(key)]
                with patch.object(LEGACY,'ROOT',root),patch('sys.argv',argv),patch.object(LEGACY,'gh',return_value=json.dumps(self.release)) as network:
                    LEGACY.main()
                network.assert_called_once_with('api',f'repos/{LEGACY.CURRENT}/releases/latest')
                self.assertEqual(self.release,before)
                self.assertEqual(list(output.rglob('*.dmg')),[])
                for site in ['current','legacy']:
                    value=json.loads((output/site/'updates/latest.json').read_text())
                    self.assertEqual(len(value['platforms']),3 if historical else 2)

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

    def test_deploy_key_survives_secret_newline_trimming(self):
        spec=importlib.util.spec_from_file_location('deploy',Path(__file__).with_name('deploy-legacy-pages.py'))
        deploy=importlib.util.module_from_spec(spec);spec.loader.exec_module(deploy)
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'key'
            subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(path)],check=True)
            original=path.read_bytes()
            for value in [original.rstrip(),original.replace(b'\n',b'\r\n').rstrip()]:
                path.write_bytes(deploy.normalized_private_key(value))
                subprocess.run(['ssh-keygen','-y','-P','','-f',str(path)],check=True,stdout=subprocess.DEVNULL)
                self.assertEqual(path.read_bytes(),original)

    def test_no_extra_compilation_job(self):
        from release_targets import RELEASE_FLAVORS
        self.assertEqual(RELEASE_FLAVORS,('legacy','arm64'))
        workflow=Path(__file__).resolve().parents[1]/'.github/workflows/repair-update-compatibility.yml'
        self.assertNotIn('package-release.py',workflow.read_text())
        self.assertNotIn('macos-',workflow.read_text())


if __name__=='__main__': unittest.main()
