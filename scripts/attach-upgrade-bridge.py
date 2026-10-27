#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Add only the audited one-time bridge assets to an unpublished 0.4.1 staging area."""
import argparse,base64,gzip,hashlib,importlib.util,json,os,plistlib,shutil,subprocess,sys,xml.etree.ElementTree as ET
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
import update_migration as M
import code_signing
ROOT=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('pages',ROOT/'scripts/build-update-pages.py');PAGES=importlib.util.module_from_spec(spec);spec.loader.exec_module(PAGES)

def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def attach(directory,artifacts,key,commit,public):
 manifest=json.loads((directory/'release-manifest.json').read_text())
 if (manifest['version'],manifest['build'])!=(M.VERSION,M.FINAL_BUILD) or 'oneTimeMigration' in manifest:raise ValueError('Bridge may be attached only once to 0.4.1 build 106')
 if base64.b64encode(key.public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw)).decode()!=public:raise ValueError('Wrong update signing key')
 if {p.name for p in artifacts.iterdir()}!={'bridge-arm64','bridge-legacy'}:raise ValueError('Exactly two bridge build artifacts are required')
 updates={}; binaries={}
 for flavor,suffix,minimum,arch in [('arm64','macOS13-arm64','13.0','arm64'),('legacy','macOS10.13-Intel','10.13','x86_64')]:
  folder=artifacts/('bridge-'+flavor);record=json.loads((folder/'manifest.json').read_text());verification=record['verification'];update=json.loads((folder/'update.json').read_text());path=folder/M.filename(suffix)
  allowed={path.name,'manifest.json','update.json'} | ({M.source_filename()} if flavor=='arm64' else set())
  if {p.name for p in folder.iterdir()}!=allowed:raise ValueError('Unexpected bridge artifact files')
  for k,v in dict(version=M.VERSION,build=M.BUILD,commit=commit,tag='v'+M.VERSION,flavor=flavor,file=path.name).items():
   if record.get(k)!=v:raise ValueError('Wrong bridge source/version')
  for k,v in dict(version=M.VERSION,build=M.BUILD,minimumOS=minimum,architectures=[arch],dmg=path.name,signing='self-signed',codeSigningCertificateSHA256=code_signing.profile()['sha256']).items():
   if verification.get(k)!=v:raise ValueError('Wrong bridge verification metadata')
  if not all(verification.get(k) for k in ['passed','signaturesVerified','allMachOMinimumsVerified','payloadMatchesStagedApp']):raise ValueError('Unverified bridge installer')
  if path.is_symlink() or digest(path)!=record['sha256'] or digest(path)!=verification['dmgSHA256'] or path.stat().st_size!=record['size']:raise ValueError('Bridge payload checksum mismatch')
  for k,v in dict(version=M.VERSION,build=M.BUILD,tag='v'+M.VERSION,flavor=flavor,file=path.name,size=path.stat().st_size,sha256=digest(path),repository=M.REPOSITORIES[0]).items():
   if update.get(k)!=v:raise ValueError('Bridge update metadata mismatch')
  # Authenticate the source feed before re-signing any aliases.
  release=dict(draft=False,prerelease=False,tag_name='v'+M.VERSION,body='<!-- oshell-update-v1:'+suffix+':'+update['signedFeed']+' -->',assets=[dict(name=path.name,size=path.stat().st_size,state='uploaded',browser_download_url=f'https://github.com/{M.REPOSITORIES[0]}/releases/download/v{M.VERSION}/{path.name}')])
  PAGES.document(release,M.REPOSITORIES[0],public,flavors=[suffix],targets=M.targets())
  enclosure=ET.fromstring(base64.b64decode(update['signedFeed'])).find('./channel/item/enclosure')
  key.public_key().verify(base64.b64decode(enclosure.get(M.NS+'edSignature'),validate=True),path.read_bytes())
  updates[flavor]=update;binaries[flavor]=path
 source=artifacts/'bridge-arm64'/M.source_filename()
 if not source.is_file() or source.is_symlink():raise ValueError('Missing audited bridge source archive')
 # All validations precede writes. Existing release artifacts are never replaced.
 for name in M.asset_names():
  if (directory/name).exists():raise ValueError('Bridge asset already exists')
 for suffix,(flavor,_) in M.CHANNELS.items():shutil.copy2(binaries[flavor],directory/M.filename(suffix))
 shutil.copy2(source,directory/source.name)
 manifest['oneTimeMigration']=dict(build=M.BUILD,commit=commit,files=[dict(file=n,size=(directory/n).stat().st_size,sha256=digest(directory/n)) for n in sorted(M.asset_names())])
 M.validate_manifest(manifest,manifest,directory)
 notes=directory/'RELEASE_NOTES.md'
 with notes.open('a') as stream:
  stream.write('\n一次性过渡附件仅供旧版应用内升级使用；全新安装请选择上表中的正式版。过渡版 build 105 完成后，将继续检查正式版 build 106。\n')
  for repo in M.REPOSITORIES:
   feeds={suffix:M.signed_feed(updates[flavor]['signedFeed'],key,repo,suffix) for suffix,(flavor,_) in M.CHANNELS.items()}
   stream.write(M.marker_text(repo,feeds)+'\n')
 (directory/'release-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
 (directory/'SHA256SUMS.txt').write_text(''.join(digest(p)+'  '+p.name+'\n' for p in sorted(directory.iterdir()) if p.name not in ['SHA256SUMS.txt','RELEASE_NOTES.md']))
 print('Prepared one-time bridge from',commit,'; no published Release modified')

def main():
 p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--artifacts',type=Path,required=True);a=p.parse_args()
 secret=os.environ.pop('OSHELL_UPDATE_SIGNING_KEY','');key=Ed25519PrivateKey.from_private_bytes(base64.b64decode(secret,validate=True))
 config=M.load_config(ROOT/'scripts/upgrade-bridge.json');public=plistlib.loads((ROOT/'scripts/Info.plist').read_bytes())['SUPublicEDKey']
 expected = subprocess.check_output(['git','archive','--format=tar','--prefix=OShell/',config['commit']],cwd=ROOT)
 source=a.artifacts/'bridge-arm64'/M.source_filename()
 if hashlib.sha256(gzip.decompress(source.read_bytes())).hexdigest()!=hashlib.sha256(expected).hexdigest():raise ValueError('Bridge source archive does not match the pinned Git commit')
 attach(a.output,a.artifacts,key,config['commit'],public)
if __name__=='__main__':main()
