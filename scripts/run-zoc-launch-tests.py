#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""Exercise the exact USM 4.1.3 ZOC argv shape against a disposable SSH server."""
import concurrent.futures, hashlib, json, os, pathlib, secrets, shutil, signal, socket, stat, subprocess, tempfile, threading, time
import paramiko
project=pathlib.Path(__file__).resolve().parent.parent
app=project/'work/test-app/OShell.app/Contents/MacOS/OShell'
launcher=app.with_name('OShell-ZOC')
with tempfile.TemporaryDirectory(prefix='oshell-zoc-',dir='/tmp') as folder:
    root=pathlib.Path(folder);key=paramiko.RSAKey.generate(2048)
    user='usm-user#asset@domain';password='ftp://pa:ss!@ "quotes" '+secrets.token_urlsafe(16)
    (root/'fixture.json').write_text(json.dumps({'password':password}));(root/'fixture.json').chmod(0o600)
    listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen();port=listener.getsockname()[1]
    (root/'known_hosts').write_text(f'[127.0.0.1]:{port} {key.get_name()} {key.get_base64()}\n')
    facts={'authenticated':0,'execRequests':0,'terms':[]};lock=threading.Lock()
    class Server(paramiko.ServerInterface):
        def check_auth_password(self,u,p):
            if u==user and p==password:
                with lock:facts['authenticated']+=1
                return paramiko.AUTH_SUCCESSFUL
            return paramiko.AUTH_FAILED
        def get_allowed_auths(self,u):return 'password'
        def check_channel_request(self,kind,chanid):return paramiko.OPEN_SUCCEEDED if kind=='session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        def check_channel_pty_request(self,channel,term,*rest):
            with lock:facts['terms'].append(term.decode())
            return True
        def check_channel_shell_request(self,channel):return True
        def check_channel_exec_request(self,channel,command):
            with lock:facts['execRequests']+=1
            return False
    def client(sock):
        transport=paramiko.Transport(sock)
        try:
            transport.add_server_key(key);transport.start_server(server=Server());channel=transport.accept(15)
            if channel is None:return
            # New sessions default to shell integration, not active host probing.
            # Report identity as the real integration script does at a prompt.
            time.sleep(.1);channel.sendall(b'USM_MOCK_READY\r\n\x1b]777;OShellHost=1;asset-real|10.20.0.9|\x07[root@asset-real ~]# ')
            while channel.recv(4096):pass
        except (OSError,EOFError,paramiko.SSHException):pass
        finally:transport.close()
    def serve():
        while True:
            try:sock,_=listener.accept()
            except OSError:return
            threading.Thread(target=client,args=(sock,),daemon=True).start()
    threading.Thread(target=serve,daemon=True).start()
    config=root/'config';env=os.environ.copy();env.update(OSHELL_DATA_DIR=str(config),OSHELL_ZOC_TEST_ROOT=folder,OSHELL_LAUNCH_NO_UI='1')
    endpoint=pathlib.Path('/tmp')/f'oshell-launch-{os.getuid()}-{hashlib.sha256(str(config).encode()).hexdigest()[:20]}'
    pid=None
    try:
        def launch(binary,title):
            args=[str(binary),'/DEV:SSH',f'/CONNECT:{user}:{password}@127.0.0.1:{port}','/EMU:Xterm','/TITLE:'+title]
            if binary==app:
                args=[str(binary),'-ssh',f'{user}@127.0.0.1:{port}','-sshpassword',password,'-emu','Xterm','-title',title]
            result=subprocess.run(args,env=env,capture_output=True,timeout=25)
            return result.returncode==0, password.encode() not in result.stdout+result.stderr
        # First request cold-starts OShell. The concurrent request must reuse it.
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(lambda title:launch(launcher,title),['USM SSH 测试','USM Telnet 资产']))
        deadline=time.time()+8
        while not (root/'app.pid').exists() and time.time()<deadline:time.sleep(.05)
        pid=int((root/'app.pid').read_text())
        endpoint=pathlib.Path((root/'endpoint.txt').read_text())
        command=subprocess.check_output(['ps','-p',str(pid),'-o','command='],text=True)
        directory_mode=stat.S_IMODE(endpoint.stat().st_mode)
        socket_mode=stat.S_IMODE((endpoint/'s').stat().st_mode)
        results.append(launch(app,'USM Rlogin 资产')) # compatibility with the path in the screenshot
        deadline=time.time()+40
        while not (root/'app-result.json').exists() and time.time()<deadline:time.sleep(.1)
        report=json.loads((root/'app-result.json').read_text())
        report['checks'].update(launcherAcceptedAll=all(r[0] for r in results),launcherDoesNotLogPassword=all(r[1] for r in results),appArgvContainsNoPassword=password not in command and '/CONNECT' not in command,privateEndpointPermissions=directory_mode==0o700 and socket_mode==0o600,realPasswordAuthentication=facts['authenticated']==3,noRemoteExec=facts['execRequests']==0,xtermPTY=facts['terms']==['xterm']*3)
        bad=subprocess.run([str(launcher),'/DEV:RLOGIN','/CONNECT:127.0.0.1'],env=env,capture_output=True,timeout=5)
        report['checks']['nativeRloginRejectedClearly']=bad.returncode!=0 and b'Rlogin' in bad.stderr
        report['passed']=all(report['checks'].values())
        (project/'validation/zoc-launch-result.json').write_text(json.dumps(report,indent=2))
        print(json.dumps(report,indent=2));raise SystemExit(0 if report['passed'] else 1)
    finally:
        listener.close()
        if pid:
            # Only the isolated app created above; never match the user's OShell.
            try:os.kill(pid,signal.SIGTERM)
            except ProcessLookupError:pass
        time.sleep(.15)
        if endpoint.exists():shutil.rmtree(endpoint)
