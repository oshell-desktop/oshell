#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""Loopback-only SFTP/SCP and FTP fixtures, rooted in a disposable directory."""
import errno, json, os, pathlib, secrets, shlex, socket, socketserver, subprocess, sys, threading, time
import paramiko
root = pathlib.Path(sys.argv[1]).resolve(); root.mkdir(parents=True, exist_ok=True)
remote_root = root/'remote'; remote_root.mkdir(exist_ok=True)
(remote_root/'seed.txt').write_text('fixture\n')
for folder, filename in [('tab-a', 'a-only.txt'), ('tab-b', 'b-only.txt')]:
    (remote_root/folder).mkdir(exist_ok=True)
    (remote_root/folder/filename).write_text('tab fixture\n')
(remote_root/'slow.bin').write_bytes(bytes(range(256)) * 32768)
for name in ['truncated.bin', 'oversized-block.bin', 'unknown-size.bin']:
    (remote_root/name).write_bytes(bytes(range(256)) * 512)
key = paramiko.RSAKey.generate(2048)
fixture = dict(user='oshell-files', password=secrets.token_urlsafe(20), master=secrets.token_urlsafe(20))

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
        try:
            attributes = paramiko.SFTPAttributes.from_stat(os.stat(resolve(path)))
            if path == '/truncated.bin': attributes.st_size += 64
            if path == '/unknown-size.bin': attributes.st_size = None
            return attributes
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
            handle.stat = lambda: paramiko.SFTPAttributes.from_stat(os.fstat(f.fileno()))
            if flags & (os.O_RDWR | os.O_WRONLY): handle.writefile = f
            if flags & os.O_RDWR or not flags & os.O_WRONLY: handle.readfile = f
            if path == '/oversized-block.bin':
                normal_read = handle.read
                handle.read = lambda offset, length: normal_read(offset, length + 1)
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
    def check_channel_env_request(self, channel, name, value):
        if name in (b'LANG', b'LANGUAGE') or name.startswith(b'LC_'):
            with (root/'locale-requests.log').open('ab') as log: log.write(name + b'\n')
        return True
    def check_auth_password(self, user, password): return paramiko.AUTH_SUCCESSFUL if user == fixture['user'] and password == fixture['password'] else paramiko.AUTH_FAILED
    def get_allowed_auths(self, user): return 'password'
    def check_channel_request(self, kind, chanid): return paramiko.OPEN_SUCCEEDED if kind == 'session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
    def check_channel_exec_request(self, channel, command):
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

def ssh_connection(client):
    transport = paramiko.Transport(client); transport.add_server_key(key); transport.set_subsystem_handler('sftp', paramiko.SFTPServer, SFTP)
    try:
        transport.start_server(server=Server())
        while transport.is_active(): time.sleep(.05)
    except Exception: pass
    finally: transport.close()
ssh = socket.socket(); ssh.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR,1); ssh.bind(('127.0.0.1',0)); ssh.listen(10)
def accept_ssh():
    while True:
        client,_ = ssh.accept(); threading.Thread(target=ssh_connection,args=(client,),daemon=True).start()
threading.Thread(target=accept_ssh,daemon=True).start()
class FTP(socketserver.StreamRequestHandler):
    def reply(self, text): self.wfile.write((text+'\r\n').encode()); self.wfile.flush()
    def passive(self):
        if self.data_listener: self.data_listener.close()
        self.data_listener=socket.socket(); self.data_listener.bind(('127.0.0.1',0)); self.data_listener.listen(1); self.data_listener.settimeout(10); return self.data_listener.getsockname()[1]
    def handle(self):
        self.cwd='/'; self.data_listener=None; authenticated=False; username=''; rename=None
        self.reply('220 OShell test FTP')
        try:
            while True:
                line=self.rfile.readline(16384)
                if not line: break
                decoded=line.decode().rstrip('\r\n'); command,_,arg=decoded.partition(' '); command=command.upper()
                if command=='USER': username=arg; self.reply('331 Password required'); continue
                if command=='PASS': authenticated=username==fixture['user'] and arg==fixture['password']; self.reply('230 Logged in' if authenticated else '530 Login failed'); continue
                if command=='QUIT': self.reply('221 Goodbye'); break
                if not authenticated: self.reply('530 Login first'); continue
                try:
                    target=resolve(arg,self.cwd) if arg else resolve(self.cwd)
                    if command=='PWD': self.reply(f'257 "{self.cwd}"')
                    elif command=='SYST': self.reply('215 UNIX Type: L8')
                    elif command=='FEAT': self.reply('211-Features\r\n UTF8\r\n MLST type*;size*;modify*;\r\n EPSV\r\n211 End')
                    elif command in ('TYPE','OPTS','NOOP'): self.reply('200 OK')
                    elif command=='CWD':
                        if not os.path.isdir(target): raise FileNotFoundError()
                        self.cwd='/' if target == str(remote_root) else '/' + os.path.relpath(target,remote_root).replace('\\','/'); self.reply('250 Directory changed')
                    elif command=='CDUP': self.cwd=os.path.dirname(self.cwd.rstrip('/')) or '/'; self.reply('250 OK')
                    elif command=='EPSV': self.reply(f'229 Entering Extended Passive Mode (|||{self.passive()}|)')
                    elif command=='PASV':
                        port=self.passive(); self.reply(f'227 Entering Passive Mode (127,0,0,1,{port//256},{port%256})')
                    elif command=='SIZE': self.reply('213 '+str(os.path.getsize(target)))
                    elif command=='MDTM': self.reply('213 20261006000000')
                    elif command=='MKD': os.mkdir(target); self.reply('257 Created')
                    elif command=='RMD': os.rmdir(target); self.reply('250 Removed')
                    elif command=='DELE': os.remove(target); self.reply('250 Deleted')
                    elif command=='RNFR':
                        if not os.path.exists(target): raise FileNotFoundError()
                        rename=target; self.reply('350 Rename target')
                    elif command=='RNTO':
                        if os.path.exists(target): raise FileExistsError()
                        os.rename(rename,target); self.reply('250 Renamed')
                    elif command in ('MLSD','NLST','LIST','RETR','STOR'):
                        if command=='MLSD' and self.cwd.startswith('/list-only'): self.reply('502 MLSD unavailable'); continue
                        self.reply('150 Opening data connection'); conn,_=self.data_listener.accept()
                        with conn:
                            if command in ('MLSD','NLST','LIST'):
                                for name in sorted(os.listdir(target)):
                                    info=os.stat(os.path.join(target,name)); kind='dir' if os.path.isdir(os.path.join(target,name)) else 'file'
                                    text=f'type={kind};size={info.st_size};modify=20261006000000;unix.mode={info.st_mode & 0o7777:04o};unix.owner=deploy;unix.group=operators; {name}' if command=='MLSD' else ((('drwxr-xr-x' if kind=='dir' else '-rw-r--r--')+f' 1 ftp ftp {info.st_size} Oct 6 08:00 {name}') if command=='LIST' else name)
                                    conn.sendall((text+'\r\n').encode())
                            elif command=='RETR':
                                with open(target,'rb') as source:
                                    while True:
                                        data=source.read(32768)
                                        if not data: break
                                        conn.sendall(data)
                                        if target.endswith('slow.bin'): time.sleep(.015)
                            else:
                                with open(target,'wb') as destination:
                                    while True:
                                        data=conn.recv(32768)
                                        if not data: break
                                        destination.write(data)
                        self.data_listener.close(); self.data_listener=None; self.reply('226 Transfer complete')
                    else: self.reply('502 Unsupported command')
                except (OSError,ValueError): self.reply('550 Operation failed')
        except (OSError,UnicodeError): pass
        finally:
            if self.data_listener: self.data_listener.close()
class FTPServer(socketserver.ThreadingTCPServer): allow_reuse_address=True; daemon_threads=True
ftp=FTPServer(('127.0.0.1',0),FTP); threading.Thread(target=ftp.serve_forever,daemon=True).start()
fixture.update(sshPort=ssh.getsockname()[1],ftpPort=ftp.server_address[1])
(root/'known_hosts').write_text(f'[127.0.0.1]:{fixture["sshPort"]} {key.get_name()} {key.get_base64()}\n')
(root/'fixture.json').write_text(json.dumps(fixture)); (root/'fixture.json').chmod(0o600)
print('File fixtures ready',flush=True)
while True: time.sleep(1)
