#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Real OpenSSH changed-key rejection and native confirmation/reconnect, using disposable keys."""
import base64, hashlib, hmac, json, os, pathlib, socket, subprocess, tempfile, threading
import paramiko

project = pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='oshell-host-key-', dir='/tmp') as folder:
    root = pathlib.Path(folder)
    old = paramiko.RSAKey.generate(2048)
    current = paramiko.RSAKey.generate(2048)
    listener = socket.socket(); listener.bind(('127.0.0.1', 0)); listener.listen()
    port = listener.getsockname()[1]; target = f'[127.0.0.1]:{port}'
    salt = os.urandom(20)
    hashed = '|1|' + base64.b64encode(salt).decode() + '|' + base64.b64encode(hmac.new(salt, target.encode(), hashlib.sha1).digest()).decode()
    key = f'{old.get_name()} {old.get_base64()}'
    original = f'# synthetic host trust\n{target},unchanged-alias {key}\n{hashed} {key}\n127.0.0.1 {key}\n[127.0.0.1]:{port+1} {key}\n192.0.2.10 {key}\n'
    (root/'known_hosts').write_text(original)
    fingerprint = lambda k: 'SHA256:' + base64.b64encode(hashlib.sha256(k.asbytes()).digest()).decode().rstrip('=')
    (root/'fixture.json').write_text(json.dumps(dict(port=port, old=fingerprint(old), new=fingerprint(current), key=current.get_base64())))
    facts = dict(authenticated=0, shells=0)
    class Server(paramiko.ServerInterface):
        def check_auth_none(self, username):
            facts['authenticated'] += 1
            return paramiko.AUTH_SUCCESSFUL
        def check_channel_request(self, kind, channel_id):
            return paramiko.OPEN_SUCCEEDED if kind == 'session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        def check_channel_pty_request(self, *args): return True
        def check_channel_shell_request(self, channel):
            facts['shells'] += 1
            def shell():
                try:
                    channel.sendall(b'HOST_KEY_RECONNECTED\r\nfixture$ ')
                    while channel.recv(4096): pass
                except (EOFError, OSError): pass
            threading.Thread(target=shell, daemon=True).start()
            return True
    def client(sock):
        transport = paramiko.Transport(sock)
        try:
            transport.add_server_key(current); transport.start_server(server=Server())
            channels = []
            while transport.is_active():
                channel = transport.accept(0.1)
                if channel is not None: channels.append(channel)
        except (EOFError, OSError, paramiko.SSHException): pass
        finally: transport.close()
    def accept():
        while True:
            try: sock, _ = listener.accept()
            except OSError: return
            threading.Thread(target=client, args=(sock,), daemon=True).start()
    threading.Thread(target=accept, daemon=True).start()
    probe = subprocess.run(['/usr/bin/ssh', '-F', '/dev/null', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'GlobalKnownHostsFile=/dev/null', '-o', f'UserKnownHostsFile={root}/known_hosts', '-p', str(port), 'fixture@127.0.0.1'], capture_output=True, timeout=10)
    (root/'diagnostic.txt').write_bytes(probe.stderr)
    (project/'validation/host-key-diagnostic.log').write_bytes(probe.stderr)
    env = os.environ.copy(); env.update(OSHELL_DATA_DIR=str(root/'client'), OSHELL_HOST_KEY_TEST_ROOT=folder)
    app = project/'work/test-app/OShell.app/Contents/MacOS/OShell'
    process = None
    try:
        with (project/'validation/host-key-app.log').open('w') as log:
            process = subprocess.Popen([str(app), '--host-key-test'], env=env, stdout=log, stderr=log)
            process.wait(timeout=60)
        report = json.loads((root/'result.json').read_text())
        report['checks']['realOpenSSHRejectsChangedKey'] = probe.returncode == 255 and b'REMOTE HOST IDENTIFICATION HAS CHANGED' in probe.stderr
        report['checks']['onlyConfirmedReconnectAuthenticates'] = facts['authenticated'] == 1 and facts['shells'] == 1
        report['server'] = facts
        report['passed'] = all(report['checks'].values()) and process.returncode == 0
        (project/'validation/host-key-result.json').write_text(json.dumps(report, indent=2, ensure_ascii=False))
        print(json.dumps(report, indent=2, ensure_ascii=False))
        raise SystemExit(0 if report['passed'] else 1)
    finally:
        listener.close()
        if process and process.poll() is None:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
