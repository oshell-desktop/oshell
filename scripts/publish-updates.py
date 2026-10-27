#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Sign existing verified DMGs. Emit internal metadata for embedding in Release notes."""
import argparse,base64,hashlib,importlib.util,json,pathlib,plistlib,re,subprocess,tempfile,xml.etree.ElementTree as ET
from release_targets import TARGETS, RELEASE_FLAVORS
ROOT=pathlib.Path(__file__).resolve().parent.parent
SPEC=importlib.util.spec_from_file_location('signing_key',ROOT/'scripts/update-signing-key.py');KEYS=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(KEYS)
SIGN=ROOT/'Vendor/Sparkle/bin/sign_update'
NAMESPACE='http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle',NAMESPACE)
def run(args): return subprocess.check_output([str(x) for x in args],text=True).strip()
def repository(value):
    value=value.removeprefix('https://github.com/').strip('/')
    if value.endswith('.git'): value=value[:-4]
    if not re.fullmatch(r'[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*/[A-Za-z0-9_.-]+',value) or value.split('/')[-1] in ['.','..']: raise ValueError('Use owner/repo or its GitHub HTTPS URL')
    return value

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository',required=True,type=repository)
    parser.add_argument('--tag',required=True)
    parser.add_argument('--private-key',type=pathlib.Path,default=KEYS.PRIVATE)
    parser.add_argument('--flavor',action='append',choices=RELEASE_FLAVORS)
    parser.add_argument('--output',type=pathlib.Path)
    args=parser.parse_args()
    info=plistlib.loads((ROOT/'scripts/Info.plist').read_bytes());version=info['CFBundleShortVersionString'];build=str(info['CFBundleVersion'])
    if args.tag!='v'+version: parser.error('Tag must match scripts/Info.plist version')
    if args.private_key.is_symlink() or args.private_key.stat().st_mode & 0o077: parser.error('Signing key permissions must be 0600')
    if KEYS.public_key(args.private_key)!=info['SUPublicEDKey']: parser.error('Private key does not match the public key embedded in the app')
    out=args.output or ROOT/'dist/updates'/version;out.mkdir(parents=True,exist_ok=True)
    report=json.loads((ROOT/'validation/package-installers-verification.json').read_text())
    for flavor in args.flavor or RELEASE_FLAVORS:
        target=TARGETS[flavor];dmg=ROOT/'dist/installers'/f'OShell-{version}-{target.suffix}.dmg'
        digest=hashlib.sha256(dmg.read_bytes()).hexdigest()
        records=[r for r in report.get('packages',[]) if r.get('flavor')==flavor]
        if not report.get('passed') or len(records)!=1: raise ValueError('Missing successful DMG verification')
        record=records[0]
        expected=dict(version=version,build=build,dmg=dmg.name,dmgSHA256=digest,minimumOS=target.minimum,architectures=sorted(target.architectures))
        if any(record.get(k)!=v for k,v in expected.items()) or not all(record.get(k) for k in ['passed','signaturesVerified','allMachOMinimumsVerified','payloadMatchesStagedApp']): raise ValueError('DMG verification is stale or incomplete')
        signature=run([SIGN,'--ed-key-file',args.private_key,'-p',dmg]);run([SIGN,'--ed-key-file',args.private_key,'--verify',dmg,signature])
        with tempfile.TemporaryDirectory(prefix='oshell-signed-metadata-') as temporary:
            feed=pathlib.Path(temporary)/'metadata.xml'
            rss=ET.Element('rss',{'version':'2.0'});channel=ET.SubElement(rss,'channel')
            ET.SubElement(channel,'title').text=f'OShell {target.suffix}'
            item=ET.SubElement(channel,'item');ET.SubElement(item,'title').text=f'OShell {version}'
            if version == '0.4.1': ET.SubElement(item,'description').text='OShell 0.4.1 正式版（build 106），需要 macOS 15 或更新系统。安装后完成升级通道迁移，后续使用正常应用内更新。'
            for name,value in [('version',build),('shortVersionString',version),('minimumSystemVersion',target.minimum)]: ET.SubElement(item,f'{{{NAMESPACE}}}{name}').text=value
            if flavor=='arm64': ET.SubElement(item,f'{{{NAMESPACE}}}hardwareRequirements').text='arm64'
            ET.SubElement(item,'enclosure',{'url':f'https://github.com/{args.repository}/releases/download/{args.tag}/{dmg.name}',f'{{{NAMESPACE}}}edSignature':signature,'length':str(dmg.stat().st_size),'type':'application/octet-stream'})
            ET.ElementTree(rss).write(feed,encoding='utf-8',xml_declaration=True)
            run([SIGN,'--ed-key-file',args.private_key,'-p',feed]);run([SIGN,'--ed-key-file',args.private_key,'--verify',feed])
            signed=base64.b64encode(feed.read_bytes()).decode()
        output=out/f'{flavor}.json'
        if output.exists(): raise ValueError('Output exists; choose an empty metadata directory')
        output.write_text(json.dumps(dict(format='OShell.release-update.v1',version=version,build=build,repository=args.repository,tag=args.tag,flavor=flavor,file=dmg.name,sha256=digest,size=dmg.stat().st_size,signedFeed=signed),indent=2)+'\n')
    print('Prepared signed DMG metadata for embedding in Release notes. No XML or update ZIP assets generated; nothing uploaded.')
if __name__=='__main__': main()
