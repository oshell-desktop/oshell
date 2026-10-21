#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""Two real PTY shells connected through nested OpenSSH; all accounts are disposable."""
import fcntl,json,os,pathlib,pty,secrets,select,signal,socket,struct,subprocess,tempfile,termios,threading
import paramiko
project=pathlib.Path(__file__).resolve().parent.parent
integration = os.environ.get('OSHELL_IDENTITY_SHELL_INTEGRATION', '1') == '1'
live_keepalive = os.environ.get('OSHELL_LIVE_KEEPALIVE_TEST') == '1'
local_password = os.environ.get('OSHELL_LOCAL_PASSWORD_TEST') == '1'
with tempfile.TemporaryDirectory(prefix='oshell-identity-',dir='/tmp') as directory:
    root=pathlib.Path(directory);key=paramiko.RSAKey.generate(2048);password=secrets.token_hex(16)
    binpath=root/'bin';binpath.mkdir()
    hostname=binpath/'hostname'
    hostname.write_text('#!/bin/sh\nprintf "%s\\n" "$OSHELL_TEST_MACHINE" >> "$OSHELL_TEST_ROOT/probes.log"\ncase "$1" in -I) printf "127.0.0.1 10.20.0.11 2001:db8::11\\n";; *) printf "%s\\n" "$OSHELL_TEST_MACHINE";; esac\n');hostname.chmod(0o700)
    facts={'authenticated':0,'execRequests':0,'shells':0,'injectedProbeCommands':0,'idleCommands':{'A':0,'B':0,'C':0}};lock=threading.Lock();pids=set()
    if integration:
        (root/'bashrc').write_text('source '+"'"+str(project/'shell-integration/oshell-integration.sh').replace("'", "'\\''")+"'\n")
    def terminal(channel,role,dimensions):
        pid,fd=pty.fork()
        if pid==0:
            fcntl.ioctl(0,termios.TIOCSWINSZ,struct.pack('HHHH',dimensions[1],dimensions[0],0,0))
            env=os.environ.copy()
            for k in list(env):
                if k.startswith('SSH_') or k.startswith('OSHELL_AUTH_'):env.pop(k,None)
            env.pop('COLUMNS',None);env.pop('LINES',None)
            env.update(PATH=str(binpath)+':/usr/bin:/bin:/usr/sbin:/sbin',TERM='xterm',PS1='[root@asset ~]# ',HISTFILE='/dev/null',BASH_SILENCE_DEPRECATION_WARNING='1',OSHELL_TEST_ROOT=str(root),OSHELL_TEST_MACHINE=role+'-real',SSH_CONNECTION='198.51.100.7 45000 '+('10.20.0.10' if role=='outer' else '10.30.0.8')+' 22')
            args=['bash','--noprofile','--rcfile',str(root/'bashrc'),'-i'] if integration else ['bash','--noprofile','--norc','-i']
            os.execve('/bin/bash',args,env)
        with lock:pids.add(pid)
        input_tail=b''
        try:
            while True:
                ready,_,_=select.select([fd,channel],[],[],.5)
                if channel.closed:break
                if fd in ready:
                    try:data=os.read(fd,32768)
                    except OSError:break
                    if not data:break
                    if role=='outer':
                        with (root/'outer-output.bin').open('ab') as capture:capture.write(data)
                    channel.sendall(data)
                if channel in ready:
                    data=channel.recv(32768)
                    if not data:break
                    with lock:
                        facts['injectedProbeCommands'] += (input_tail+data).count(b'OSHELL_INFO_')
                        if live_keepalive:
                            for token in ['A','B','C']: facts['idleCommands'][token] += (input_tail+data).count(('echo LIVE_'+token+'\r').encode())
                            temp=root/'idle-inputs.tmp';temp.write_text(json.dumps(facts['idleCommands']));temp.replace(root/'idle-inputs.json')
                    input_tail=(input_tail+data)[-11:]
                    os.write(fd,data)
        except (EOFError,OSError):pass
        finally:
            os.close(fd)
            try:os.kill(pid,signal.SIGHUP)
            except ProcessLookupError:pass
            try:os.waitpid(pid,0)
            except ChildProcessError:pass
            with lock:pids.discard(pid)
            try:channel.send_exit_status(0)
            except (EOFError,OSError):pass
            channel.close()
    class Server(paramiko.ServerInterface):
        def __init__(self,role):self.role=role;self.dimensions={}
        def check_auth_password(self,u,p):
            if u=='test' and p==password:
                with lock:facts['authenticated']+=1
                return paramiko.AUTH_SUCCESSFUL
            return paramiko.AUTH_FAILED
        def get_allowed_auths(self,u):return 'password'
        def check_channel_request(self,kind,chanid):return paramiko.OPEN_SUCCEEDED if kind=='session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        def check_channel_pty_request(self,channel,term,width,height,*args):
            self.dimensions[channel.get_id()]=(max(20,width),max(2,height));return True
        def check_channel_shell_request(self,channel):
            with lock:facts['shells']+=1
            threading.Thread(target=terminal,args=(channel,self.role,self.dimensions.get(channel.get_id(),(100,30))),daemon=True).start();return True
        def check_channel_exec_request(self,channel,command):
            with lock:facts['execRequests']+=1
            return False
    def connection(sock,role):
        transport=paramiko.Transport(sock)
        try:
            transport.add_server_key(key);transport.start_server(server=Server(role));channels=[]
            while transport.is_active():
                channel=transport.accept(1)
                if channel is not None:channels.append(channel)
        except (EOFError,OSError,paramiko.SSHException):pass
        finally:transport.close()
    def accept(listener,role):
        while True:
            try:sock,_=listener.accept()
            except OSError:return
            threading.Thread(target=connection,args=(sock,role),daemon=True).start()
    listeners=[];fixture={'password':password,'integration':integration}
    for role in ['outer','inner']:
        listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen();listeners.append(listener);fixture[role+'Port']=listener.getsockname()[1]
        threading.Thread(target=accept,args=(listener,role),daemon=True).start()
    (root/'fixture.json').write_text(json.dumps(fixture));(root/'fixture.json').chmod(0o600)
    (root/'known_hosts').write_text(''.join(f'[127.0.0.1]:{fixture[role+"Port"]} {key.get_name()} {key.get_base64()}\n' for role in ['outer','inner']))
    zdot=root/'zsh';zdot.mkdir();(zdot/'.zshrc').write_text("PS1='oshell@%m:~$ '\nHISTFILE=/dev/null\nSAVEHIST=0\n")
    if integration:
        with (zdot/'.zshrc').open('a') as rc: rc.write('source '+"'"+str(project/'shell-integration/oshell-integration.sh').replace("'", "'\\''")+"'\n")
    env=os.environ.copy();env.update(OSHELL_DATA_DIR=str(root/'config'),OSHELL_IDENTITY_TEST_ROOT=str(root),OSHELL_BACKGROUND_TEST='1',ZDOTDIR=str(zdot))
    app=None
    try:
        with (project/'validation/host-identity-app.log').open('wb') as log:
            app=subprocess.Popen([str(project/'work/test-app/OShell.app/Contents/MacOS/OShell'),'--local-password-test' if local_password else ('--live-keepalive-test' if live_keepalive else '--host-identity-test')],env=env,stdout=log,stderr=log)
            app.wait(timeout=120)
        report=json.loads((root/'result.json').read_text());report['server']=facts
        report['checks']['noExecChannelOnBastion']=facts['execRequests']==0
        report['checks']['expectedAuthentications']=facts['authenticated']==(1 if live_keepalive or local_password else (4 if integration else 2))
        report['checks']['expectedShells']=facts['shells']==(1 if local_password else (2 if live_keepalive else (5 if integration else 2)))
        report['checks']['noInjectedProbeCommands']=facts['injectedProbeCommands']==0
        report['probeHosts']=(root/'probes.log').read_text().splitlines() if (root/'probes.log').exists() else []
        report['passed']=report['passed'] and all(report['checks'].values()) and app.returncode==0
        if not report['passed'] and (root/'outer-output.bin').exists():
            (project/'validation/host-identity-echo.bin').write_bytes((root/'outer-output.bin').read_bytes()[:16384])
        (project/'validation/host-identity-result.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2));raise SystemExit(0 if report['passed'] else 1)
    finally:
        if app and app.poll() is None:app.terminate();app.wait(timeout=5)
        for listener in listeners:listener.close()
        with lock:remaining=list(pids)
        for pid in remaining:
            try:os.kill(pid,signal.SIGHUP)
            except ProcessLookupError:pass
