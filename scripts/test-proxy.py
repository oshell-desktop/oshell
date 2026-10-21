#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""Loopback protocol and duplex/backpressure checks for OShellProxy (stdlib only)."""
import json, os, socket, struct, subprocess, sys, tempfile, threading

def exact(sock, n):
    data = b''
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk: raise EOFError()
        data += chunk
    return data

def zero(sock):
    out = b''
    while True:
        b = exact(sock, 1)
        if b == b'\0': return out
        out += b

def fixture(sock, kind, host, user, password, reject):
    if kind in ('socks4', 'socks4a'):
        head = exact(sock, 8)
        assert head[:2] == b'\x04\x01' and head[2:4] == struct.pack('!H', 2222)
        assert zero(sock) == user.encode()
        if kind == 'socks4a': assert head[4:] == b'\0\0\0\1' and zero(sock).decode() == host
        else: assert head[4:] == socket.inet_aton(host)
        sock.sendall(bytes([0, 91 if reject else 90]) + b'\0' * 6)
    elif kind == 'socks5':
        assert exact(sock, 3) == bytes([5, 1, 2 if user else 0])
        sock.sendall(bytes([5, 2 if user else 0]))
        if user:
            assert exact(sock, 1) == b'\1'
            assert exact(sock, exact(sock, 1)[0]).decode() == user
            assert exact(sock, exact(sock, 1)[0]).decode() == password
            sock.sendall(b'\1\0')
        header = exact(sock, 4); assert header[:3] == b'\5\1\0'
        if header[3] == 1: target = socket.inet_ntop(socket.AF_INET, exact(sock, 4))
        elif header[3] == 4: target = socket.inet_ntop(socket.AF_INET6, exact(sock, 16))
        else: target = exact(sock, exact(sock, 1)[0]).decode()
        assert target == host and exact(sock, 2) == struct.pack('!H', 2222)
        sock.sendall(bytes([5, 5 if reject else 0, 0, 3, 3]) + b'dns' + b'\x08\xae')
    else:
        import base64
        header = b''
        while not header.endswith(b'\r\n\r\n'): header += exact(sock, 1)
        authority = f'[{host}]:2222' if ':' in host else f'{host}:2222'
        assert header.startswith(f'CONNECT {authority} HTTP/1.1\r\n'.encode())
        if user: assert b'Proxy-Authorization: Basic ' + base64.b64encode(f'{user}:{password}'.encode()) in header
        sock.sendall(b'HTTP/1.1 407 Denied\r\n\r\n' if reject else b'HTTP/1.1 200 OK\r\n\r\n')
    if not reject:
        while True:
            data = sock.recv(16384)
            if not data: break
            sock.sendall(data)
        sock.sendall(b'END')

def main():
    results = []
    for kind, host, user, reject in [('socks4', '127.0.0.1', '', False), ('socks4a', 'fixture.test', 'userid', False), ('socks5', 'fixture.test', '', False), ('socks5', '127.0.0.1', 'alice', False), ('socks5', '::1', '', False), ('http', 'fixture.test', '', False), ('http', '::1', 'alice', False), ('socks4', '127.0.0.1', '', True), ('socks5', 'fixture.test', '', True), ('http', 'fixture.test', '', True)]:
        with tempfile.TemporaryDirectory(prefix='op-', dir='/tmp') as root:
            errors = []; password = 'fixture-secret'
            listener = socket.socket(); listener.bind(('127.0.0.1', 0)); listener.listen(); listener.settimeout(10)
            def serve():
                try:
                    conn, _ = listener.accept()
                    with conn: conn.settimeout(10); fixture(conn, kind, host, user, password, reject)
                except Exception as error: errors.append(repr(error))
            thread = threading.Thread(target=serve); thread.start()
            env = os.environ.copy(); auth = None
            if user and kind in ('socks5', 'http'):
                auth = socket.socket(socket.AF_UNIX); path = root + '/s'; auth.bind(path); auth.listen(); auth.settimeout(10)
                env.update(OSHELL_AUTH_SOCKET=path, OSHELL_AUTH_TOKEN='fixture-token')
                def authenticate():
                    conn, _ = auth.accept()
                    with conn:
                        request = json.loads(exact(conn, struct.unpack('!I', exact(conn, 4))[0]))
                        assert request['token'] == 'fixture-token' and request['hint'] == 'oshell-proxy'
                        response = json.dumps(dict(success=True, answer=password)).encode()
                        conn.sendall(struct.pack('!I', len(response)) + response)
                auth_thread = threading.Thread(target=authenticate); auth_thread.start()
            args = [sys.argv[1], '--type', kind, '--host', '127.0.0.1', '--port', str(listener.getsockname()[1]), '--user', user, '--target-host', host, '--target-port', '2222']
            payload = bytes(range(256)) * 4096
            result = subprocess.run(args, input=payload, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=20)
            thread.join(2); listener.close()
            if auth: auth_thread.join(2); auth.close()
            passed = not errors and ((result.returncode != 0) if reject else result.returncode == 0 and result.stdout == payload + b'END') and password.encode() not in result.stderr
            results.append(dict(type=kind, target=host, authenticated=bool(user), rejection=reject, passed=passed, errors=errors))
    report = dict(passed=all(r['passed'] for r in results), cases=results)
    print(json.dumps(report, indent=2)); return 0 if report['passed'] else 1
if __name__ == '__main__': sys.exit(main())
