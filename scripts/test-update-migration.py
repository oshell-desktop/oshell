#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Signed synthetic fixtures for immutable bridge metadata and long-lived modern feeds."""
import base64,copy,importlib.util,json,tempfile,unittest
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
import update_migration as M
from release_targets import TARGETS
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('pages',ROOT/'scripts/build-update-pages.py');P=importlib.util.module_from_spec(spec);spec.loader.exec_module(P)

class MigrationTests(unittest.TestCase):
 def setUp(self):
  self.key=getattr(self,"key",None) or Ed25519PrivateKey.generate();self.public=base64.b64encode(self.key.public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw)).decode()
  self.release={'tag_name':'v0.4.1','draft':False,'prerelease':False,'body':'','assets':[]};feeds={r:{} for r in M.REPOSITORIES}
  for suffix,(flavor,minimum) in M.CHANNELS.items():
   data=b'fixture-'+flavor.encode();signature=base64.b64encode(self.key.sign(data)).decode()
   xml=f'<rss xmlns:sparkle="{M.NS[1:-1]}"><channel><item><sparkle:version>105</sparkle:version><sparkle:shortVersionString>0.4.1</sparkle:shortVersionString><sparkle:minimumSystemVersion>{minimum}</sparkle:minimumSystemVersion><enclosure url="unused" length="{len(data)}" sparkle:edSignature="{signature}"/></item></channel></rss>'.encode()
   for repo in feeds:feeds[repo][suffix]=M.signed_feed(base64.b64encode(xml).decode(),self.key,repo,suffix)
   self.release['assets'].append(dict(name=M.filename(suffix),state='uploaded',size=len(data),browser_download_url=f'https://github.com/{M.REPOSITORIES[0]}/releases/download/v0.4.1/{M.filename(suffix)}'))
  self.feeds=feeds;self.release['body']='\n'.join(M.marker_text(repo,f) for repo,f in feeds.items())
 def document(self,repo=None):return M.document(self.release,repo or M.REPOSITORIES[0],self.public,P)
 def test_both_repositories_keep_the_old_contract_and_real_system_floors(self):
  for repo in M.REPOSITORIES:
   d=self.document(repo);self.assertEqual((d['version'],d['build'],d['repository']),('0.4.1','105',repo));self.assertEqual(set(d['platforms']),set(M.CHANNELS))
 def test_same_payload_signature_reused_for_aliases(self):
  import xml.etree.ElementTree as ET
  signatures={suffix:ET.fromstring(base64.b64decode(feed)).find('./channel/item/enclosure').get(M.NS+'edSignature') for suffix,feed in self.feeds[M.REPOSITORIES[0]].items()}
  self.assertEqual(signatures['macOS15-arm64'],signatures['macOS13-arm64'])
  self.assertEqual(signatures['macOS15-amd64'],signatures['macOS10.13-Intel'])
 def test_tampered_feed_is_rejected(self):
  feeds=self.feeds[M.REPOSITORIES[0]];s='macOS13-arm64';feeds[s]=base64.b64encode(base64.b64decode(feeds[s]).replace(b'>105<',b'>106<')).decode();self.release['body']=M.marker_text(M.REPOSITORIES[0],feeds)
  with self.assertRaises(Exception):self.document()
 def test_even_signed_wrong_build_is_rejected(self):
  import xml.etree.ElementTree as ET
  feeds=self.feeds[M.REPOSITORIES[0]]
  for suffix in feeds:
   tree=ET.fromstring(base64.b64decode(feeds[suffix]));tree.find('./channel/item/'+M.NS+'version').text='106';raw=ET.tostring(tree)
   feeds[suffix]=base64.b64encode(raw+f'<!-- sparkle-signatures:\nedSignature: {base64.b64encode(self.key.sign(raw)).decode()}\nlength: {len(raw)}\n-->\n'.encode()).decode()
  self.release['body']=M.marker_text(M.REPOSITORIES[0],feeds)
  with self.assertRaisesRegex(ValueError,'frozen'):self.document()
 def test_missing_duplicate_or_extra_channels_are_rejected(self):
  original=copy.deepcopy(self.release)
  for mode in ['missing','duplicate','extra']:
   self.release=copy.deepcopy(original)
   if mode=='duplicate':self.release['body']*=2
   else:
    feeds=copy.deepcopy(self.feeds[M.REPOSITORIES[0]])
    if mode=='missing':feeds.pop('macOS15-arm64')
    else:feeds['unknown']=next(iter(feeds.values()))
    self.release['body']=M.marker_text(M.REPOSITORIES[0],feeds)
   with self.assertRaises(ValueError):self.document()
 def test_missing_payload_and_foreign_download_host_are_rejected(self):
  original=copy.deepcopy(self.release)
  for mode in ['missing','foreign','length']:
   self.release=copy.deepcopy(original)
   if mode=='missing':self.release['assets'].pop()
   elif mode=='foreign':self.release['assets'][0]['browser_download_url']='https://example.invalid/file.dmg'
   else:self.release['assets'][0]['size']+=1
   with self.assertRaises(ValueError):self.document()
 def test_no_old_platform_is_added_to_modern_build_catalog(self):
  self.assertEqual(set(TARGETS),{'arm64','amd64'});self.assertTrue(all(t.minimum=='15.0' for t in TARGETS.values()))
 def test_original_endpoint_stays_frozen_when_modern_version_advances(self):
  frozen=self.document();modern=dict(frozen,version='0.5.0',build='120',platforms={})
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp)/'site';P.write_site(modern,root,frozen)
   self.assertEqual(json.loads((root/'updates/latest.json').read_text()),frozen)
   self.assertEqual(json.loads((root/'updates/macos15.json').read_text()),modern)
 def test_migration_never_accepts_a_different_release_or_repo(self):
  with self.assertRaises(ValueError):self.document('untrusted/repo')
  self.release['tag_name']='v0.4.2'
  with self.assertRaises(ValueError):self.document()

class AttachmentTests(unittest.TestCase):
 def setUp(self):
  MigrationTests.setUp(self)
  import hashlib
  spec=importlib.util.spec_from_file_location('attach',ROOT/'scripts/attach-upgrade-bridge.py');self.A=importlib.util.module_from_spec(spec);spec.loader.exec_module(self.A)
  self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name);self.out=self.root/'output';self.out.mkdir();self.incoming=self.root/'input';self.incoming.mkdir();self.commit='a'*40
  (self.out/'release-manifest.json').write_text(json.dumps(dict(version='0.4.1',build='106',commit='b'*40)))
  (self.out/'RELEASE_NOTES.md').write_text('Fixture notes\n')
  for flavor,suffix,minimum,arch in [('arm64','macOS13-arm64','13.0','arm64'),('legacy','macOS10.13-Intel','10.13','x86_64')]:
   folder=self.incoming/('bridge-'+flavor);folder.mkdir();data=b'fixture-'+flavor.encode();name=M.filename(suffix);(folder/name).write_bytes(data);digest=hashlib.sha256(data).hexdigest()
   verification=dict(version='0.4.1',build='105',minimumOS=minimum,architectures=[arch],dmg=name,dmgSHA256=digest,passed=True,signaturesVerified=True,allMachOMinimumsVerified=True,payloadMatchesStagedApp=True,signing='self-signed',codeSigningCertificateSHA256=self.A.code_signing.profile()['sha256'])
   record=dict(version='0.4.1',build='105',commit=self.commit,tag='v0.4.1',flavor=flavor,file=name,sha256=digest,size=len(data),verification=verification)
   update=dict(version='0.4.1',build='105',tag='v0.4.1',flavor=flavor,file=name,sha256=digest,size=len(data),repository=M.REPOSITORIES[0],signedFeed=self.feeds[M.REPOSITORIES[0]][suffix])
   (folder/'manifest.json').write_text(json.dumps(record));(folder/'update.json').write_text(json.dumps(update))
   if flavor=='arm64':(folder/M.source_filename()).write_bytes(b'synthetic audited source')
 def attach(self):self.A.attach(self.out,self.incoming,self.key,self.commit,self.public)
 def snapshot(self):return {p.name:p.read_bytes() for p in self.out.iterdir()}
 def test_attach_round_trip_and_identical_alias_bytes(self):
  self.attach();manifest=json.loads((self.out/'release-manifest.json').read_text());self.assertEqual(M.validate_manifest(manifest,manifest,self.out),M.asset_names())
  release=dict(self.release,body=(self.out/'RELEASE_NOTES.md').read_text())
  for repo in M.REPOSITORIES:self.assertEqual(M.document(release,repo,self.public,P)['build'],'105')
  self.assertEqual((self.out/M.filename('macOS13-arm64')).read_bytes(),(self.out/M.filename('macOS15-arm64')).read_bytes())
  with self.assertRaises(ValueError):self.attach()
 def test_tampered_bridge_rejected_before_any_write(self):
  before=self.snapshot();path=self.incoming/'bridge-arm64'/M.filename('macOS13-arm64');path.write_bytes(b'x'*path.stat().st_size)
  with self.assertRaises(ValueError):self.attach()
  self.assertEqual(self.snapshot(),before)
 def test_wrong_source_commit_or_key_rejected_before_write(self):
  before=self.snapshot();self.commit='c'*40
  with self.assertRaises(ValueError):self.attach()
  self.assertEqual(self.snapshot(),before)
  self.commit='a'*40;self.key=Ed25519PrivateKey.generate()
  with self.assertRaises(ValueError):self.attach()
  self.assertEqual(self.snapshot(),before)
 def test_unexpected_artifact_and_modified_published_manifest_rejected(self):
  (self.incoming/'bridge-arm64/extra.dmg').write_bytes(b'extra')
  with self.assertRaises(ValueError):self.attach()
  (self.incoming/'bridge-arm64/extra.dmg').unlink();self.attach()
  manifest=json.loads((self.out/'release-manifest.json').read_text());(self.out/M.filename('macOS15-amd64')).write_bytes(b'changed')
  with self.assertRaises(ValueError):M.validate_manifest(manifest,manifest,self.out)

if __name__=='__main__':unittest.main()
