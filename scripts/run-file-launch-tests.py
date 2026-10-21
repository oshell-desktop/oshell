#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""Exact USM --site launch contract with disposable XML/SFTP/FTP fixtures."""
import base64,concurrent.futures,json,os,pathlib,plistlib,signal,subprocess,sys,tempfile,time,urllib.parse,xml.etree.ElementTree as ET
project=pathlib.Path(__file__).resolve().parent.parent
app=project/'work/test-app/OShell.app';bridge=app/'Contents/Helpers/OShell-FileZilla.app/Contents/MacOS/OShell-FileZilla'
with tempfile.TemporaryDirectory(prefix='oshell-file-launch-',dir='/tmp') as folder:
    root=pathlib.Path(folder);server=None;pid=None
    try:
        with (root/'server.log').open('wb') as log:
            server=subprocess.Popen([sys.executable,str(project/'scripts/file-test-server.py'),folder],stdout=log,stderr=log)
            deadline=time.time()+10
            while not (root/'fixture.json').exists() and time.time()<deadline:time.sleep(.05)
            fixture=json.loads((root/'fixture.json').read_text())
            document=ET.Element('FileZilla3',{'version':'3.70.0','platform':'mac'});sites=ET.SubElement(document,'Servers');group=ET.SubElement(sites,'Folder');group.text='usmsso'
            for protocol,port,name in [('1',fixture['sshPort'],'user-SFTP 资产'),('0',fixture['ftpPort'],'user-FTP 资产')]:
                node=ET.SubElement(group,'Server')
                for key,value in [('Host','127.0.0.1'),('Port',str(port)),('Protocol',protocol),('Type','0'),('User',fixture['user']),('Logontype','1'),('Name',name)]:ET.SubElement(node,key).text=value
                ET.SubElement(node,'Pass',{'encoding':'base64'}).text=base64.b64encode(fixture['password'].encode()).decode()
            sitefile=root/'sitemanager.xml';ET.ElementTree(document).write(sitefile,encoding='utf-8',xml_declaration=True);sitefile.chmod(0o600);before=sitefile.read_bytes()
            config=root/'config';env=os.environ.copy();env.update(OSHELL_DATA_DIR=str(config),OSHELL_FILEZILLA_CONFIG=str(sitefile),OSHELL_FILE_LAUNCH_TEST_ROOT=folder,OSHELL_LAUNCH_NO_UI='1')
            def launch(args,binary=bridge):return subprocess.run([str(binary),*args],env=env,capture_output=True,timeout=30)
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(lambda name:launch(['--site=0/usmsso/'+name]),['user-SFTP 资产','user-FTP 资产']))
            deadline=time.time()+10
            while not (root/'app.pid').exists() and time.time()<deadline:time.sleep(.05)
            pid=int((root/'app.pid').read_text())
            url='sftp://'+urllib.parse.quote(fixture['user'],safe='')+':'+urllib.parse.quote(fixture['password'],safe='')+'@127.0.0.1:'+str(fixture['sshPort'])+'/'
            results.append(launch([url],app/'Contents/MacOS/OShell'))
            deadline=time.time()+85
            while not (root/'launch-result.json').exists() and time.time()<deadline:time.sleep(.1)
            report=json.loads((root/'launch-result.json').read_text());checks=report['checks']
            info=plistlib.loads(bridge.parents[1].joinpath('Info.plist').read_bytes())
            checks['usmMetadataSelectsModernFileZillaLayout']=info['CFBundleShortVersionString']=='3.70.0' and info['CFBundleVersion']=='3.70.0'
            checks['allLaunchersAccepted']=all(x.returncode==0 for x in results)
            checks['noPasswordInLauncherOutput']=all(fixture['password'].encode() not in x.stdout+x.stderr for x in results)
            checks['siteConfigurationNotModified']=sitefile.read_bytes()==before
            bad=launch(['--site=0/usmsso/missing']);checks['missingSiteRejectedWithoutSecrets']=bad.returncode!=0 and fixture['password'].encode() not in bad.stdout+bad.stderr
            sitefile.write_text('<FileZilla3><Pass>'+fixture['password']+'</broken>')
            bad=launch(['--site=0/usmsso/broken']);checks['malformedXMLDoesNotLeakCredentials']=bad.returncode!=0 and fixture['password'].encode() not in bad.stdout+bad.stderr
            report['passed']=all(checks.values());(project/'validation/file-launch-result.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2));raise SystemExit(0 if report['passed'] else 1)
    finally:
        if (root/'server.log').exists():(project/'validation/file-launch-server.log').write_bytes((root/'server.log').read_bytes())
        if pid:
            try:os.kill(pid,signal.SIGTERM)
            except ProcessLookupError:pass
        if server and server.poll() is None:server.terminate();server.wait(timeout=5)
