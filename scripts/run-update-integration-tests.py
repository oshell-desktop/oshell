#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""Real Sparkle validation/installation in disposable app copies; never updates dist or /Applications."""
import argparse,base64,functools,hashlib,http.server,json,os,pathlib,plistlib,shutil,subprocess,tempfile,threading,time,uuid,xml.etree.ElementTree as ET
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
ROOT=pathlib.Path(__file__).resolve().parent.parent
SIGN=ROOT/'Vendor/Sparkle/bin/sign_update'
NS='http://www.andymatuschak.org/xml-namespaces/sparkle';ET.register_namespace('sparkle',NS)
def run(args): return subprocess.check_output([str(x) for x in args],stderr=subprocess.STDOUT,text=True).strip()
def hash_file(path): return hashlib.sha256(path.read_bytes()).hexdigest()
class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self,*args): pass
results=[]
parser=argparse.ArgumentParser(); parser.add_argument('--modes', nargs='+', default=['no-update','static-no-update','static-tampered','network-error','unsigned-feed','tampered-feed','bad-archive','cancel','install']); args=parser.parse_args()
for mode in args.modes:
 with tempfile.TemporaryDirectory(prefix='oshell-update-test-',dir='/tmp') as folder:
    root=pathlib.Path(folder);live=root/'live/OShell.app';new=root/'next/OShell.app';config=root/'config';config.mkdir(); web=root/'web';web.mkdir()
    private=Ed25519PrivateKey.generate();seed=private.private_bytes(serialization.Encoding.Raw,serialization.PrivateFormat.Raw,serialization.NoEncryption())
    key=root/'test-private.key';key.write_bytes(base64.b64encode(seed));key.chmod(0o600)
    public=base64.b64encode(private.public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw)).decode()
    bundle_id='app.oshell.update-test.'+uuid.uuid4().hex
    run(['ditto',ROOT/'work/test-app/OShell.app',live])
    info_path=live/'Contents/Info.plist';info=plistlib.loads(info_path.read_bytes());old_build=int(info['CFBundleVersion']);new_build=old_build+10000
    info.update(CFBundleIdentifier=bundle_id,SUPublicEDKey=public);info.pop('SUDefaultsDomain',None)
    info_path.write_bytes(plistlib.dumps(info));run(['codesign','--force','--sign','-',live])
    old_digest=hash_file(info_path)
    run(['ditto',live,new]);after=dict(info,CFBundleVersion=str(new_build),OShellUpdateTestAfter=True,OShellUpdateTestRoot=folder)
    (new/'Contents/Info.plist').write_bytes(plistlib.dumps(after));run(['codesign','--force','--sign','-',new])
    image=root/'image';image.mkdir();run(['ditto',new,image/'OShell.app']);(image/'Applications').symlink_to('/Applications')
    archive=web/'update.dmg';run(['hdiutil','create','-quiet','-format','UDZO','-fs','HFS+','-volname','OShell Update Test','-srcfolder',image,archive])
    signature=run([SIGN,'--ed-key-file',key,'-p',archive])
    if mode=='bad-archive':
        with archive.open('ab') as f:f.write(b'tampered-test-data')
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Handler,directory=str(web)))
    port=server.server_address[1];threading.Thread(target=server.serve_forever,daemon=True).start()
    feed=web/'appcast.xml';rss=ET.Element('rss',{'version':'2.0'});channel=ET.SubElement(rss,'channel');ET.SubElement(channel,'title').text='Isolated test'
    item=ET.SubElement(channel,'item');ET.SubElement(item,'title').text='Test update'
    ET.SubElement(item,f'{{{NS}}}version').text=str(old_build if mode in ['no-update','static-no-update'] else new_build)
    ET.SubElement(item,f'{{{NS}}}shortVersionString').text=info['CFBundleShortVersionString']
    ET.SubElement(item,f'{{{NS}}}minimumSystemVersion').text='15.0'
    uses_release = mode in ['no-update','unsigned-feed','tampered-feed','static-no-update','static-tampered']
    name=f"OShell-{info['CFBundleShortVersionString']}-macOS-arm64.dmg"
    archive_url=f"https://github.com/example-org/OShell/releases/download/v{info['CFBundleShortVersionString']}/{name}" if uses_release else f'http://127.0.0.1:{port}/update.dmg'
    ET.SubElement(item,'enclosure',{'url':archive_url,'length':str(archive.stat().st_size),'type':'application/octet-stream',f'{{{NS}}}edSignature':signature})
    ET.ElementTree(rss).write(feed,encoding='utf-8',xml_declaration=True)
    if mode!='unsigned-feed': run([SIGN,'--ed-key-file',key,'-p',feed])
    if mode in ['tampered-feed','static-tampered']:feed.write_bytes(feed.read_bytes().replace(b'Test update',b'Changed update'))
    release=web/'release.json';release.write_text(json.dumps(dict(draft=False,prerelease=False,tag_name='v'+info['CFBundleShortVersionString'],body='<!-- oshell-update-v1:macOS-arm64:'+base64.b64encode(feed.read_bytes()).decode()+' -->',assets=[dict(name=name,size=archive.stat().st_size,state='uploaded',browser_download_url=archive_url)])))
    if mode in ['static-no-update','static-tampered']:
        release.write_text(json.dumps(dict(format='OShell.static-updates.v1',repository='example-org/OShell',version=info['CFBundleShortVersionString'],build=str(old_build if mode=='static-no-update' else new_build),platforms={'macOS-arm64':dict(file=name,size=archive.stat().st_size,signedFeed=base64.b64encode(feed.read_bytes()).decode())})))
    config_file=config/'configuration.json';config_file.write_text('{"profiles":[],"preferences":{}}');config_digest=hash_file(config_file)
    env=os.environ.copy();env.update(OSHELL_DATA_DIR=str(config),OSHELL_BACKGROUND_TEST='1',OSHELL_UPDATE_INTEGRATION_ROOT=folder,OSHELL_UPDATE_INTEGRATION_MODE=mode)
    env['OSHELL_UPDATE_INTEGRATION_RELEASE' if uses_release else 'OSHELL_UPDATE_INTEGRATION_FEED_FILE']=str(release if uses_release else (web/'missing.xml' if mode=='network-error' else feed))
    process=None
    try:
        with open(ROOT/f'validation/updater-integration-{mode}.log','w') as log:
            process=subprocess.Popen([str(live/'Contents/MacOS/OShell'),'--update-integration-test'],env=env,stdout=log,stderr=log)
            process.wait(timeout=85)
        result=json.loads((root/'result.json').read_text()) if (root/'result.json').exists() else {'outcome':'missing-report'}
        if mode=='install':
            deadline=time.time()+35
            while not (root/'relaunch.json').exists() and time.time()<deadline:time.sleep(.2)
            result['relaunched']= (root/'relaunch.json').exists()
            result['newVersionInstalled']=plistlib.loads(info_path.read_bytes())['CFBundleVersion']==str(new_build)
            passed=result.get('cancelKeptSession') and result.get('secondConfirmationAccepted') and result['relaunched'] and result['newVersionInstalled'] and result.get('downloadedBytes',0)>0
        else:
            result['originalAppUnchanged']=hash_file(info_path)==old_digest
            expected='no-update' if mode in ['no-update','static-no-update'] else ('cancelled' if mode=='cancel' else 'rejected')
            passed=result.get('outcome')==expected and result['originalAppUnchanged'] and not result.get('ready',False)
        result['configurationUnchanged']=hash_file(config_file)==config_digest
        result.update(mode=mode,passed=bool(passed and result['configurationUnchanged'] and process.returncode==0))
        results.append(result);print(json.dumps(result),flush=True)
    finally:
        if process and process.poll() is None:process.kill();process.wait()
        server.shutdown();server.server_close()
        # Only clean domains uniquely created by this test, never app.oshell.mac.
        subprocess.run(['defaults','delete',bundle_id],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        cache=pathlib.Path.home()/'Library/Caches'/bundle_id
        if cache.exists():shutil.rmtree(cache)
report={'passed':all(r['passed'] for r in results),'cases':results}
(ROOT/'validation/updater-integration-result.json').write_text(json.dumps(report,indent=2))
raise SystemExit(0 if report['passed'] else 1)
