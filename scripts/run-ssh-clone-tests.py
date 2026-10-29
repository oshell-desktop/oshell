#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""USM launch + real SSH multiplexing, with one password authentication total."""
import json,os,pathlib,secrets,shutil,signal,socket,subprocess,tempfile,threading,time
import paramiko,re
project=pathlib.Path(__file__).resolve().parent.parent
launcher=project/'work/test-app/OShell.app/Contents/MacOS/OShell-ZOC'
with tempfile.TemporaryDirectory(prefix='oshell-clone-',dir='/tmp') as folder:
    root=pathlib.Path(folder);key=paramiko.RSAKey.generate(2048)
    user='clone-user#asset';password='one-use!@:'+secrets.token_urlsafe(20)
    (root/'fixture.json').write_text(json.dumps({'password':password}));(root/'fixture.json').chmod(0o600)
    listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen();port=listener.getsockname()[1]
    (root/'known_hosts').write_text(f'[127.0.0.1]:{port} {key.get_name()} {key.get_base64()}\n')
    # Seed host trust before the external launcher can start SSH; its service
    # may become ready before the main-loop fixture callback runs.
    (root/'config').mkdir()
    shutil.copy2(root/'known_hosts', root/'config/known_hosts')
    facts={'transports':0,'authenticated':0,'shells':0,'rejected':0,'execRequests':0,'terms':[],'localeRequests':0};lock=threading.Lock()
    def session(channel):
        try:
            time.sleep(.05);channel.send(b'MUX_READY\r\n\x1b]777;OShellHost=1;nested-real|10.30.0.8|\x07[root@nested-real ~]# ');line=bytearray()
            while True:
                data=channel.recv(1024)
                if not data:return
                for c in data:
                    if c in (10,13):
                        value=bytes(line);line.clear()
                        token=re.search(rb'OSHELL_INFO_[0-9A-F]+:',value)
                        if token:channel.sendall(value+b'\r\n\x1b]2;'+token.group()+b'nested-real|10.30.0.8|\x07[root@nested-host ~]# ')
                        elif value:channel.send(b'REPLY_'+value+b'\r\n[root@nested-real ~]# ')
                    elif 32<=c<127:line.append(c)
        except (OSError,EOFError):pass
        finally:channel.close()
    class Server(paramiko.ServerInterface):
        def get_banner(self): return ("中文登录提示：仅供授权人员使用。\nLiteral \\350\\277\\231 stays literal.\n", "zh-CN")
        def check_channel_env_request(self,channel,name,value):
            if name in (b'LANG',b'LANGUAGE') or name.startswith(b'LC_'):
                with lock:facts['localeRequests']+=1
            return True
        def check_auth_password(self,u,p):
            with lock:
                # The ticket is genuinely one-use: a fresh login cannot succeed again.
                if u==user and p==password and facts['authenticated']==0:
                    facts['authenticated']+=1;return paramiko.AUTH_SUCCESSFUL
            return paramiko.AUTH_FAILED
        def get_allowed_auths(self,u):return 'password'
        def check_channel_request(self,kind,chanid):
            with lock:
                flag=root/'reject-next'
                if flag.exists():flag.unlink();facts['rejected']+=1;return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
            return paramiko.OPEN_SUCCEEDED if kind=='session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        def check_channel_pty_request(self,channel,term,*args):
            with lock:facts['terms'].append(term.decode())
            return True
        def check_channel_shell_request(self,channel):
            with lock:facts['shells']+=1
            threading.Thread(target=session,args=(channel,),daemon=True).start();return True
        def check_channel_exec_request(self,channel,command):
            with lock:facts['execRequests']+=1
            return False
    def client(sock):
        transport=paramiko.Transport(sock)
        with lock:facts['transports']+=1
        try:
            transport.add_server_key(key);transport.start_server(server=Server());channels=[]
            while transport.is_active():
                channel=transport.accept(1)
                if channel is not None:channels.append(channel)
        except (OSError,EOFError,paramiko.SSHException):pass
        finally:transport.close()
    def serve():
        while True:
            try:sock,_=listener.accept()
            except OSError:return
            threading.Thread(target=client,args=(sock,),daemon=True).start()
    threading.Thread(target=serve,daemon=True).start()
    env=os.environ.copy();env.update(OSHELL_DATA_DIR=str(root/'config'),OSHELL_ZOC_CLONE_TEST_ROOT=folder,OSHELL_LAUNCH_NO_UI='1',LANG='en_US.UTF-8',LC_CTYPE='UTF-8',LC_ALL='C')
    pid=None;endpoint=None;gui=None
    try:
        # Key-equivalent checks need a LaunchServices-activated application,
        # rather than a background Process launched by the CLI bridge.
        command=['open','-n','-W']
        for env_name in ['OSHELL_DATA_DIR','OSHELL_ZOC_CLONE_TEST_ROOT','OSHELL_LAUNCH_NO_UI','LANG','LC_CTYPE','LC_ALL']:
            command += ['--env',env_name+'='+env[env_name]]
        command += ['--stdout',str(root/'app.log'),'--stderr',str(root/'app.log'),str(project/'work/test-app/OShell.app'),'--args','--external-launch-service']
        gui=subprocess.Popen(command,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        readiness=time.monotonic()+12
        while not (root/'app.pid').exists() and not (root/'app-result.json').exists() and gui.poll() is None and time.monotonic()<readiness:time.sleep(.05)
        if (root/'app.pid').exists():pid=int((root/'app.pid').read_text())
        result=subprocess.run([str(launcher),'/DEV:SSH',f'/CONNECT:{user}:{password}@127.0.0.1:{port}','/EMU:Xterm','/TITLE:USM 克隆测试'],env=env,capture_output=True,timeout=25)
        # The launch socket can accept before the main-loop test callback runs.
        ready_deadline = time.monotonic()+5
        while result.returncode == 0 and not (root/'app.pid').exists() and not (root/'app-result.json').exists() and time.monotonic() < ready_deadline:
            time.sleep(.05)
        if not (root/'app.pid').exists():
            diagnostic = {'launcherExit': result.returncode, 'launcherError': result.stderr.decode(errors='replace').replace(password, '[redacted]')}
            if (root/'app-result.json').exists(): diagnostic['fixture'] = json.loads((root/'app-result.json').read_text())
            raise RuntimeError(json.dumps(diagnostic, ensure_ascii=False))
        pid=int((root/'app.pid').read_text());endpoint=pathlib.Path((root/'endpoint.txt').read_text())
        deadline=time.time()+65
        while not (root/'app-result.json').exists() and time.time()<deadline:time.sleep(.1)
        report=json.loads((root/'app-result.json').read_text())
        report['checks'].update(initialLaunchAccepted=result.returncode==0,oneTransportOnly=facts['transports']==1,oneAuthenticationOnly=facts['authenticated']==1,fourIndependentRemoteShells=facts['shells']==4,serverRejectionExercised=facts['rejected']==1,xtermPreserved=facts['terms']==['xterm']*4,noRemoteExec=facts['execRequests']==0)
        report['server']=facts
        report['checks']['clientLocaleNotForwarded']=facts['localeRequests']==0
        report['passed']=all(report['checks'].values())
        (project/'validation/ssh-clone-result.json').write_text(json.dumps(report,indent=2))
        print(json.dumps(report,indent=2));raise SystemExit(0 if report['passed'] else 1)
    finally:
        listener.close()
        if pid:
            deadline=time.time()+3
            while time.time()<deadline:
                try:os.kill(pid,0)
                except ProcessLookupError:break
                time.sleep(.05)
            else:
                try:os.kill(pid,signal.SIGTERM)
                except ProcessLookupError:pass
        if gui:
            try:gui.wait(timeout=5)
            except subprocess.TimeoutExpired:gui.terminate();gui.wait(timeout=5)
        if endpoint and endpoint.exists():shutil.rmtree(endpoint)
