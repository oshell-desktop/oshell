#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""Isolated SSH/legacy/proxy/tunnel fixture. Requires paramiko, binds loopback only."""
import json, os, re, secrets, select, socket, struct, sys, threading, time
from pathlib import Path
import paramiko

original_channel_request = paramiko.channel.Channel._handle_request
def channel_request(channel, message):
    if paramiko.Message(message.get_remainder()).get_text() == 'keepalive@openssh.com': record('aliveMessages')
    return original_channel_request(channel, message)
paramiko.Transport._channel_handler_table[98] = channel_request

root = Path(sys.argv[1]); root.mkdir(parents=True, exist_ok=True)
(root/"server.pid").write_text(str(os.getpid()))
key = paramiko.RSAKey.generate(2048)
fixture = {'user': 'oshell-test', 'password': secrets.token_urlsafe(20), 'master': secrets.token_urlsafe(20), 'proxyPassword': secrets.token_urlsafe(20)}
state = dict(authenticated=0, idleMessages=0, aliveMessages=0, proxyAuthentications=0, localForwards=0, remoteForwards=0, remoteForwardRequests=0, localeRequests=0)
lock = threading.Lock()
def record(key):
    with lock:
        state[key] += 1
        (root/'server-result.json').write_text(json.dumps(state))
def listener():
    sock = socket.socket(); sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); sock.bind(('127.0.0.1', 0)); sock.listen(10); return sock
ssh_legacy, ssh_modern, echo_listener, proxy_listener = [listener() for _ in range(4)]
fixture.update(legacyPort=ssh_legacy.getsockname()[1], modernPort=ssh_modern.getsockname()[1], echoPort=echo_listener.getsockname()[1], proxyPort=proxy_listener.getsockname()[1])
for keyname in ['localPort', 'remotePort', 'dynamicPort']:
    temp = listener(); fixture[keyname] = temp.getsockname()[1]; temp.close()
(root/'fixture.json').write_text(json.dumps(fixture)); (root/'fixture.json').chmod(0o600)
(root/'known_hosts').write_text(''.join(f'[127.0.0.1]:{port} {key.get_name()} {key.get_base64()}\n' for port in [fixture['legacyPort'], fixture['modernPort']]))
def relay(a, b):
    try:
        while True:
            ready, _, _ = select.select([a, b], [], [], 30)
            if not ready: continue
            for src in ready:
                data = src.recv(65536)
                if not data: return
                (b if src is a else a).sendall(data)
    except Exception: pass
    finally: a.close(); b.close()
def serve_loop(sock, handler):
    while True:
        try: conn, addr = sock.accept()
        except OSError: return
        threading.Thread(target=handler, args=(conn,), daemon=True).start()
def echo(conn):
    with conn:
        while True:
            data = conn.recv(65536)
            if not data: return
            conn.sendall(data)
class Server(paramiko.ServerInterface):
    def __init__(self, transport): self.transport = transport; self.destinations = {}; self.commands = {}; self.forwards = []; self.plainPrompt = False
    def get_allowed_auths(self, username): return 'password'
    def check_auth_password(self, username, password):
        if username in (fixture['user'], fixture['user']+'-plain') and password == fixture['password']:
            self.plainPrompt = username.endswith('-plain'); record('authenticated'); return paramiko.AUTH_SUCCESSFUL
        return paramiko.AUTH_FAILED
    def check_channel_request(self, kind, chanid): return paramiko.OPEN_SUCCEEDED if kind == 'session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
    def check_channel_pty_request(self, *args): return True
    def check_channel_shell_request(self, channel): self.commands[channel.get_id()] = b''; return True
    def check_channel_exec_request(self, channel, command): self.commands[channel.get_id()] = command; return True
    def check_channel_direct_tcpip_request(self, chanid, origin, destination):
        if destination[0] != '127.0.0.1' or destination[1] not in [fixture['echoPort'], fixture['legacyPort'], fixture['modernPort']]: return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        self.destinations[chanid] = destination; record('localForwards'); return paramiko.OPEN_SUCCEEDED
    def check_port_forward_request(self, address, port):
        record('remoteForwardRequests')
        if address != '127.0.0.1' or port != fixture['remotePort']: return False
        sock = socket.socket(); sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); sock.bind((address, port)); sock.listen(); self.forwards.append(sock)
        def forward(conn):
            try:
                channel = self.transport.open_forwarded_tcpip_channel(conn.getpeername(), sock.getsockname()); record('remoteForwards'); relay(conn, channel)
            except Exception: conn.close()
        threading.Thread(target=serve_loop, args=(sock, forward), daemon=True).start(); return port
    def check_global_request(self, kind, msg):
        if kind == 'keepalive@openssh.com': record('aliveMessages')
        return False
    def check_channel_env_request(self, channel, name, value):
        if name in (b'LANG', b'LANGUAGE') or name.startswith(b'LC_'): record('localeRequests')
        return True

def session_channel(channel, server):
    deadline = time.time() + 10
    while channel.get_id() not in server.commands and time.time() < deadline: time.sleep(.02)
    prompt = b'> ' if server.plainPrompt else b'[root@centos6-fixture ~]# '
    channel.send(b'\r\nOSHELL_SESSION_READY\r\n'+prompt)
    line = bytearray()
    try:
        while True:
            data = channel.recv(4096)
            if not data: break
            for byte in data:
                if byte in (10,13):
                    command=bytes(line);line.clear()
                    token=re.search(rb'OSHELL_INFO_[0-9A-F]+:',command)
                    if token: channel.sendall(command+b'\r\n\x1b]2;'+token.group()+b'centos6-fixture|10.6.0.6|\x07[root@centos6-fixture ~]# ')
                    elif b'OSHELL_IDLE' in command: record('idleMessages');channel.send(b'\r\nIDLE_RECEIVED\r\n'+prompt)
                    elif command:channel.sendall(command+b'\r\n[root@centos6-fixture ~]# ')
                else:line.append(byte)
    except Exception: pass
    channel.close()
def ssh(conn, legacy):
    transport = paramiko.Transport(conn); transport.add_server_key(key)
    if legacy:
        options = transport.get_security_options(); options.kex = ['diffie-hellman-group14-sha1']; options.key_types = ['ssh-rsa']; options.ciphers = ['aes128-cbc']; options.digests = ['hmac-sha1']
    server = Server(transport)
    try:
        transport.start_server(server=server)
        while transport.is_active():
            channel = transport.accept(1)
            if not channel: continue
            if channel.get_id() in server.destinations:
                target = socket.create_connection(server.destinations[channel.get_id()]); threading.Thread(target=relay, args=(channel, target), daemon=True).start()
            else: threading.Thread(target=session_channel, args=(channel, server), daemon=True).start()
    except Exception: pass
    finally:
        transport.close()
        for sock in server.forwards: sock.close()
def exact(sock, n):
    data = b''
    while len(data) < n:
        b = sock.recv(n-len(data))
        if not b: raise EOFError()
        data += b
    return data
def proxy(conn):
    try:
        assert exact(conn, 3) == b'\5\1\2'; conn.sendall(b'\5\2')
        assert exact(conn, 1) == b'\1'
        user = exact(conn, exact(conn, 1)[0]).decode(); password = exact(conn, exact(conn, 1)[0]).decode()
        assert user == 'proxy-user' and password == fixture['proxyPassword']; record('proxyAuthentications'); conn.sendall(b'\1\0')
        header = exact(conn, 4); assert header[:3] == b'\5\1\0'
        if header[3] == 1: host = socket.inet_ntoa(exact(conn, 4))
        else: host = exact(conn, exact(conn, 1)[0]).decode()
        port = struct.unpack('!H', exact(conn, 2))[0]
        assert host == '127.0.0.1' and port in [fixture['legacyPort'], fixture['modernPort']]
        target = socket.create_connection((host, port)); conn.sendall(b'\5\0\0\1\x7f\0\0\1' + struct.pack('!H', port)); relay(conn, target)
    except Exception: conn.close()
for sock, handler in [(ssh_legacy, lambda c: ssh(c, True)), (ssh_modern, lambda c: ssh(c, False)), (echo_listener, echo), (proxy_listener, proxy)]:
    threading.Thread(target=serve_loop, args=(sock, handler), daemon=True).start()
print('Session fixture ready', flush=True)
while True: time.sleep(1)
