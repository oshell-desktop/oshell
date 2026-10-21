#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""USM one-use ticket: SSH, SFTP and SCP share one authenticated transport."""
import json,os,pathlib,secrets,shutil,signal,socket,subprocess,tempfile,threading,time
import paramiko,re,errno,shlex
project=pathlib.Path(__file__).resolve().parent.parent
launcher=pathlib.Path(os.environ.get('OSHELL_TEST_APP',str(project/'work/test-app/OShell.app')))/'Contents/MacOS/OShell-ZOC'
with tempfile.TemporaryDirectory(prefix='oshell-sftp-reuse-',dir='/tmp') as folder:
    root=pathlib.Path(folder).resolve();key=paramiko.RSAKey.generate(2048)
    remote_root=root/'remote';remote_root.mkdir();(remote_root/'seed.txt').write_text('seed fixture\n')
    user='clone-user#asset';password='one-use!@:'+secrets.token_urlsafe(20)
    (root/'fixture.json').write_text(json.dumps({'password':password}));(root/'fixture.json').chmod(0o600)
    listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen();port=listener.getsockname()[1]
    (root/'known_hosts').write_text(f'[127.0.0.1]:{port} {key.get_name()} {key.get_base64()}\n')
    facts={'transports':0,'authAttempts':0,'sftp':0,'sftpDenied':0,'authenticated':0,'shells':0,'rejected':0,'execRequests':0,'terms':[],'localeRequests':0};lock=threading.Lock()
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
    def resolve(path, cwd='/'):
        virtual = path if path.startswith('/') else cwd.rstrip('/') + '/' + path
        candidate = os.path.realpath(os.path.join(remote_root, virtual.lstrip('/')))
        if os.path.commonpath([candidate, str(remote_root)]) != str(remote_root): raise PermissionError(errno.EACCES, 'outside fixture')
        return candidate
    class SFTP(paramiko.SFTPServerInterface):
        def list_folder(self, path):
            try:
                base = resolve(path); result = []
                for name in os.listdir(base):
                    attr = paramiko.SFTPAttributes.from_stat(os.lstat(os.path.join(base, name))); attr.filename = name; result.append(attr)
                return result
            except OSError as e: return paramiko.SFTPServer.convert_errno(e.errno)
        def stat(self, path):
            try: return paramiko.SFTPAttributes.from_stat(os.stat(resolve(path)))
            except OSError as e: return paramiko.SFTPServer.convert_errno(e.errno)
        def lstat(self, path):
            try: return paramiko.SFTPAttributes.from_stat(os.lstat(resolve(path)))
            except OSError as e: return paramiko.SFTPServer.convert_errno(e.errno)
        def canonicalize(self, path):
            try: return '/' if resolve(path) == str(remote_root) else '/' + os.path.relpath(resolve(path), remote_root).replace('\\','/')
            except OSError: return '/'
        def open(self, path, flags, attr):
            try:
                fd = os.open(resolve(path), flags, 0o600)
                handle = paramiko.SFTPHandle(flags)
                mode = 'r+b' if flags & os.O_RDWR else 'wb' if flags & os.O_WRONLY else 'rb'
                f = os.fdopen(fd, mode)
                if flags & (os.O_RDWR | os.O_WRONLY): handle.writefile = f
                if flags & os.O_RDWR or not flags & os.O_WRONLY: handle.readfile = f
                return handle
            except OSError as e: return paramiko.SFTPServer.convert_errno(e.errno)
        def remove(self, path): return self.mutate(os.remove, resolve(path))
        def mkdir(self, path, attr): return self.mutate(os.mkdir, resolve(path))
        def rmdir(self, path): return self.mutate(os.rmdir, resolve(path))
        def rename(self, old, new):
            if os.path.exists(resolve(new)): return paramiko.SFTP_FAILURE
            return self.mutate(os.rename, resolve(old), resolve(new))
        def mutate(self, function, *args):
            try: function(*args); return paramiko.SFTP_OK
            except OSError as e: return paramiko.SFTPServer.convert_errno(e.errno)
    class Server(paramiko.ServerInterface):
        def check_channel_env_request(self,channel,name,value):
            if name in (b'LANG',b'LANGUAGE') or name.startswith(b'LC_'):
                with lock:facts['localeRequests']+=1
            return True
        def check_auth_password(self,u,p):
            with lock:
                facts['authAttempts']+=1
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
        def check_channel_subsystem_request(self,channel,name):
            with lock:
                if (root/'deny-sftp').exists():facts['sftpDenied']+=1;return False
                facts['sftp']+=1
            return super().check_channel_subsystem_request(channel,name)
        def check_channel_exec_request(self, channel, command):
            with lock:facts['execRequests']+=1
            try:
                args = shlex.split(command.decode())
                if args[0] != 'scp' or not set(args[1:-1]).issubset({'-r','-t','-f','-d','-p','--'}): return False
                target = resolve(args[-1])
                def run():
                    p = subprocess.Popen(['/usr/bin/scp', *args[1:-1], target], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    def incoming():
                        try:
                            while True:
                                data = channel.recv(65536)
                                if not data: break
                                p.stdin.write(data); p.stdin.flush()
                        except Exception: pass
                        finally:
                            try: p.stdin.close()
                            except Exception: pass
                    def errors():
                        try:
                            while True:
                                data = os.read(p.stderr.fileno(), 4096)
                                if not data: break
                                channel.send_stderr(data)
                        except Exception: pass
                    threading.Thread(target=incoming, daemon=True).start(); threading.Thread(target=errors, daemon=True).start()
                    try:
                        while True:
                            data = os.read(p.stdout.fileno(), 65536)
                            if not data: break
                            channel.sendall(data)
                        p.wait(timeout=10); channel.send_exit_status(p.returncode)
                    except Exception: p.kill()
                    finally: channel.close()
                threading.Thread(target=run, daemon=True).start(); return True
            except Exception: return False
    def client(sock):
        transport=paramiko.Transport(sock)
        transport.set_subsystem_handler('sftp',paramiko.SFTPServer,SFTP)
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
    env=os.environ.copy();env.update(OSHELL_DATA_DIR=str(root/'config'),OSHELL_SFTP_REUSE_TEST_ROOT=folder,OSHELL_LAUNCH_NO_UI='1',LANG='en_US.UTF-8',LC_CTYPE='UTF-8',LC_ALL='C')
    pid=None;endpoint=None;app=None
    try:
        # Start the isolated fixture before delivering its one-use ticket, so
        # AppKit initialization cannot consume the IPC socket read timeout.
        app=subprocess.Popen([str(launcher.parent/'OShell'),'--external-launch-service'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        deadline=time.time()+15
        while not (root/'app.pid').exists() and app.poll() is None and time.time()<deadline:time.sleep(.05)
        result=subprocess.run([str(launcher),'/DEV:SSH',f'/CONNECT:{user}:{password}@127.0.0.1:{port}','/EMU:Xterm','/TITLE:USM 文件连接复用测试'],env=env,capture_output=True,timeout=25)
        pid=int((root/'app.pid').read_text());endpoint=pathlib.Path((root/'endpoint.txt').read_text())
        deadline=time.time()+65
        while not (root/'app-result.json').exists() and time.time()<deadline:time.sleep(.1)
        report=json.loads((root/'app-result.json').read_text())
        report['checks'].update(initialLaunchAccepted=result.returncode==0,oneTransportOnly=facts['transports']==1,oneAuthenticationOnly=facts['authenticated']==1 and facts['authAttempts']==1,fourSFTPChannels=facts['sftp']==4,SFTPRefusalExercised=facts['sftpDenied']==1,SCPCommandsReusedConnection=facts['execRequests']==2)
        report['server']=facts
        if result.returncode: report['launchError']=result.stderr.decode(errors='replace').replace(password,'<fixture-secret>').replace(user,'<fixture-user>')[:300]
        report['checks']['clientLocaleNotForwarded']=facts['localeRequests']==0
        report['passed']=all(report['checks'].values())
        (project/'validation/sftp-reuse-result.json').write_text(json.dumps(report,indent=2))
        print(json.dumps(report,indent=2));raise SystemExit(0 if report['passed'] else 1)
    finally:
        listener.close()
        if pid is None and app is not None: pid=app.pid
        if pid:
            deadline=time.time()+3
            while time.time()<deadline:
                try:os.kill(pid,0)
                except ProcessLookupError:break
                time.sleep(.05)
            else:
                try:os.kill(pid,signal.SIGTERM)
                except ProcessLookupError:pass
        if endpoint and endpoint.exists():shutil.rmtree(endpoint)
