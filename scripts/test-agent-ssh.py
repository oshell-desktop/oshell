#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Disposable loopback SSH service with a real Bash PTY; rejects SSH exec channels."""
import fcntl, json, os, pty, secrets, select, signal, socket, struct, termios, threading
from pathlib import Path
import paramiko

class Fixture:
    def __init__(self, root):
        self.root=Path(root);self.closed=False;self.children=[];self.transports=[]
        self.facts={'authenticated':0,'shells':0,'execRequests':0}
        self.key=paramiko.RSAKey.generate(2048);self.password=secrets.token_hex(20)
        self.listener=socket.socket();self.listener.bind(('127.0.0.1',0));self.listener.listen(4);self.port=self.listener.getsockname()[1]
        (self.root/'known_hosts').write_text(f'[127.0.0.1]:{self.port} {self.key.get_name()} {self.key.get_base64()}\n')
        (self.root/'agent-ssh.json').write_text(json.dumps(dict(port=self.port,password=self.password)));(self.root/'agent-ssh.json').chmod(0o600)
        threading.Thread(target=self.accept,daemon=True).start()
    def accept(self):
        while not self.closed:
            try:connection,_=self.listener.accept()
            except OSError:return
            threading.Thread(target=self.connection,args=(connection,),daemon=True).start()
    def connection(self,connection):
        fixture=self
        class Server(paramiko.ServerInterface):
            def get_allowed_auths(self,user):return 'password'
            def check_auth_password(self,user,password):
                if user=='fixture' and password==fixture.password:fixture.facts['authenticated']+=1;return paramiko.AUTH_SUCCESSFUL
                return paramiko.AUTH_FAILED
            def check_channel_request(self,kind,chanid):return paramiko.OPEN_SUCCEEDED if kind=='session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
            def check_channel_pty_request(self,*args):return True
            def check_channel_exec_request(self,channel,command):fixture.facts['execRequests']+=1;return False
            def check_channel_shell_request(self,channel):
                fixture.facts['shells']+=1;threading.Thread(target=fixture.shell,args=(channel,),daemon=True).start();return True
        transport=paramiko.Transport(connection);self.transports.append(transport)
        try:
            transport.add_server_key(self.key);transport.start_server(server=Server())
            channels=[]
            while not self.closed and transport.is_active():
                channel=transport.accept(1)
                if channel is not None:channels.append(channel)
        except (OSError,EOFError,paramiko.SSHException):pass
        finally:transport.close()
    def shell(self,channel):
        child,fd=pty.fork()
        if child==0:
            os.chdir(self.root)
            os.execve('/bin/bash',['bash','--noprofile','--norc','-i'],dict(HOME=str(self.root),PATH='/usr/bin:/bin',TERM='xterm-256color',PS1='oshell-agent-fixture$ ',LC_ALL='en_US.UTF-8'))
        self.children.append(child)
        fcntl.ioctl(fd,termios.TIOCSWINSZ,struct.pack('HHHH',30,100,0,0))
        try:
            while not self.closed and not channel.closed:
                ready,_,_=select.select([fd,channel],[],[],.1)
                if fd in ready:
                    data=os.read(fd,65536)
                    if not data:break
                    channel.sendall(data)
                if channel in ready:
                    data=channel.recv(65536)
                    if not data:break
                    os.write(fd,data)
        except (OSError,EOFError):pass
        finally:
            os.close(fd);channel.close()
            try:os.kill(child,signal.SIGHUP)
            except ProcessLookupError:pass
            try:os.waitpid(child,0)
            except ChildProcessError:pass
    def close(self):
        self.closed=True;self.listener.close()
        for transport in self.transports:transport.close()
        for child in self.children:
            try:os.kill(child,signal.SIGHUP)
            except ProcessLookupError:pass
