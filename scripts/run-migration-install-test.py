#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Two real Sparkle installs with three source-built apps and synthetic isolated identity/data."""
import argparse,base64,functools,hashlib,http.server,json,os,plistlib,shutil,subprocess,tempfile,threading,time,uuid,xml.etree.ElementTree as ET
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
ROOT=Path(__file__).resolve().parents[1];SIGN=ROOT/'Vendor/Sparkle/bin/sign_update';NS='http://www.andymatuschak.org/xml-namespaces/sparkle';ET.register_namespace('sparkle',NS)
def run(args):return subprocess.check_output(list(map(str,args)),stderr=subprocess.STDOUT,text=True).strip()
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
class Handler(http.server.SimpleHTTPRequestHandler):
 def log_message(self,*args):pass

def main():
 p=argparse.ArgumentParser();p.add_argument('--old-app',type=Path,required=True);p.add_argument('--bridge-app',type=Path,required=True);p.add_argument('--modern-app',type=Path,required=True);a=p.parse_args()
 apps=[a.old_app.resolve(),a.bridge_app.resolve(),a.modern_app.resolve()]
 for app in apps:
  if not plistlib.loads((app/'Contents/Info.plist').read_bytes()).get('OShellTestHarness'):raise ValueError('Only isolated test apps are allowed')
 report=[]
 with tempfile.TemporaryDirectory(prefix='oshell-update-test-',dir='/tmp') as temp:
  root=Path(temp);live=root/'live/OShell.app';config=root/'config';config.mkdir();configfile=config/'configuration.json';configfile.write_text('{"profiles":[],"preferences":{}}');configdigest=digest(configfile)
  key=Ed25519PrivateKey.generate();keyfile=root/'signing.key';keyfile.touch(mode=0o600);keyfile.write_bytes(base64.b64encode(key.private_bytes(serialization.Encoding.Raw,serialization.PrivateFormat.Raw,serialization.NoEncryption())))
  public=base64.b64encode(key.public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw)).decode();bundle='app.oshell.migration-test.'+uuid.uuid4().hex
  def prepare(source,target,after=False):
   run(['ditto',source,target]);p=target/'Contents/Info.plist';info=plistlib.loads(p.read_bytes())
   info.update(CFBundleIdentifier=bundle,SUPublicEDKey=public,OShellUpdateRepository='');info.pop('SUDefaultsDomain',None)
   if after:info.update(OShellUpdateTestAfter=True,OShellUpdateTestRoot=temp)
   else:info.pop('OShellUpdateTestAfter',None);info.pop('OShellUpdateTestRoot',None)
   p.write_bytes(plistlib.dumps(info));run(['codesign','--force','--sign','-',target]);return info
  prepare(apps[0],live)
  try:
   for step,source in enumerate(apps[1:],1):
    # Preserve the installed bridge and same configuration for the second hop.
    if step==2:
     info=plistlib.loads((live/'Contents/Info.plist').read_bytes());info.pop('OShellUpdateTestAfter',None);info.pop('OShellUpdateTestRoot',None)
     (live/'Contents/Info.plist').write_bytes(plistlib.dumps(info));run(['codesign','--force','--sign','-',live])
    oldbuild=plistlib.loads((live/'Contents/Info.plist').read_bytes())['CFBundleVersion'];image=root/f'image-{step}';image.mkdir();target=image/'OShell.app';nextinfo=prepare(source,target,True)
    archive=root/f'update-{step}.dmg';run(['hdiutil','create','-quiet','-format','UDZO','-fs','HFS+','-volname','OShell Migration Test','-srcfolder',image,archive]);signature=run([SIGN,'--ed-key-file',keyfile,'-p',archive])
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Handler,directory=str(root)));threading.Thread(target=server.serve_forever,daemon=True).start()
    feed=root/f'feed-{step}.xml';rss=ET.Element('rss',{'version':'2.0'});item=ET.SubElement(ET.SubElement(rss,'channel'),'item');ET.SubElement(item,'title').text='Migration fixture'
    for name,val in [('version',nextinfo['CFBundleVersion']),('shortVersionString',nextinfo['CFBundleShortVersionString']),('minimumSystemVersion',nextinfo['LSMinimumSystemVersion'])]:ET.SubElement(item,f'{{{NS}}}'+name).text=val
    ET.SubElement(item,'enclosure',{'url':f'http://127.0.0.1:{server.server_address[1]}/{archive.name}','length':str(archive.stat().st_size),'type':'application/octet-stream',f'{{{NS}}}edSignature':signature})
    ET.ElementTree(rss).write(feed,encoding='utf-8',xml_declaration=True);run([SIGN,'--ed-key-file',keyfile,'-p',feed])
    for name in ['result.json','relaunch.json']:(root/name).unlink(missing_ok=True)
    env=dict(os.environ,OSHELL_DATA_DIR=str(config),OSHELL_BACKGROUND_TEST='1',OSHELL_UPDATE_INTEGRATION_ROOT=temp,OSHELL_UPDATE_INTEGRATION_MODE='install',OSHELL_UPDATE_INTEGRATION_FEED_FILE=str(feed))
    env.pop('OSHELL_UPDATE_INTEGRATION_RELEASE',None)
    process=None
    try:
     with (ROOT/f'validation/migration-install-{step}.log').open('w') as log:
      process=subprocess.Popen([str(live/'Contents/MacOS/OShell'),'--update-integration-test'],env=env,stdout=log,stderr=log);process.wait(timeout=100)
     deadline=time.monotonic()+35
     while not (root/'relaunch.json').exists() and time.monotonic()<deadline:time.sleep(.2)
     result=json.loads((root/'result.json').read_text());installed=plistlib.loads((live/'Contents/Info.plist').read_bytes())
     result.update(step=step,fromBuild=oldbuild,toBuild=installed['CFBundleVersion'],relaunched=(root/'relaunch.json').exists(),configurationUnchanged=digest(configfile)==configdigest)
     result['passed']=process.returncode==0 and result.get('cancelKeptSession') and result.get('secondConfirmationAccepted') and result['relaunched'] and result['toBuild']==nextinfo['CFBundleVersion'] and result['configurationUnchanged']
     report.append(result);print(json.dumps(result),flush=True)
     if not result['passed']:raise RuntimeError('Migration install failed')
    finally:
     if process and process.poll() is None:process.kill();process.wait()
     server.shutdown();server.server_close()
  finally:
   subprocess.run(['defaults','delete',bundle],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
   (ROOT/'validation/migration-install-chain.json').write_text(json.dumps(report,indent=2)+'\n')
 print('PASS: old → bridge → modern, two verified downloads/installations/relaunches, cancellation and configuration preservation')
if __name__=='__main__':main()
