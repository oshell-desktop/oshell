#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Opt-in real loopback-model + real PTY test; key travels only in an anonymous pipe."""
import argparse, getpass, json, os, plistlib, secrets, socket, subprocess, tempfile, threading, time, uuid
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent

class SSHFixture:
    """Real OpenSSH transport to a loopback echo shell which never executes code."""
    def __init__(self, directory):
        import paramiko
        self.listener = socket.socket(); self.listener.bind(('127.0.0.1', 0)); self.listener.listen()
        self.port = self.listener.getsockname()[1]
        self.username, self.password = 'ai-fixture', secrets.token_urlsafe(24)
        self.commands, self.returns, self.execs, self.auths = [], 0, 0, 0
        self.transports = []; self.lock = threading.Lock()
        host_key = paramiko.RSAKey.generate(2048)
        (directory/'known_hosts').write_text(f'[127.0.0.1]:{self.port} {host_key.get_name()} {host_key.get_base64()}\n')
        fixture = self
        def shell(channel):
            prompt = b'[fixture@ai-ssh ~]$ '
            try:
                time.sleep(.1); channel.sendall(prompt); line = bytearray()
                while True:
                    block = channel.recv(4096)
                    if not block: return
                    for c in block:
                        if c == 21:
                            with fixture.lock: fixture.commands.append(bytes(line))
                            line.clear(); channel.sendall(b'\r\x1b[2K' + prompt)
                        elif c in (10, 13):
                            with fixture.lock: fixture.returns += 1
                            line.clear(); channel.sendall(b'\r\n' + prompt)
                        elif 32 <= c < 127:
                            line.append(c); channel.sendall(bytes([c]))
            except (OSError, EOFError): pass
            finally: channel.close()
        class Server(paramiko.ServerInterface):
            def check_auth_password(self, username, password):
                if username == fixture.username and password == fixture.password:
                    with fixture.lock: fixture.auths += 1
                    return paramiko.AUTH_SUCCESSFUL
                return paramiko.AUTH_FAILED
            def get_allowed_auths(self, username): return 'password'
            def check_channel_request(self, kind, channel):
                return paramiko.OPEN_SUCCEEDED if kind == 'session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
            def check_channel_pty_request(self, channel, *args): return True
            def check_channel_shell_request(self, channel):
                threading.Thread(target=shell, args=(channel,), daemon=True).start(); return True
            def check_channel_exec_request(self, channel, command):
                with fixture.lock: fixture.execs += 1
                return False
        def client(sock):
            transport = paramiko.Transport(sock)
            with self.lock: self.transports.append(transport)
            try:
                transport.add_server_key(host_key); transport.start_server(server=Server()); channels = []
                while transport.is_active():
                    channel = transport.accept(1)
                    if channel is not None: channels.append(channel)
            except (OSError, EOFError, paramiko.SSHException): pass
            finally: transport.close()
        def serve():
            while True:
                try: sock, _ = self.listener.accept()
                except OSError: return
                threading.Thread(target=client, args=(sock,), daemon=True).start()
        threading.Thread(target=serve, daemon=True).start()
    def result(self):
        with self.lock:
            return dict(sshOneAuthentication=self.auths == 1, sshExactlyOneUnsubmittedCommand=self.commands == [b'printf OSHELL_AI_INSERT_OK'], sshNoReturnSent=self.returns == 0, sshNoRemoteExec=self.execs == 0)
    def close(self):
        self.listener.close()
        with self.lock:
            for transport in self.transports: transport.close()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--endpoint', required=True)
    parser.add_argument('--model', required=True)
    parser.add_argument('--ssh', action='store_true', help='Also verify a real loopback SSH connection (requires paramiko).')
    parser.add_argument('--models-only', action='store_true', help='Only fetch the model list; no model inference or terminal session.')
    args = parser.parse_args()
    if args.models_only and args.ssh: parser.error('--models-only cannot be combined with --ssh')
    url = urlsplit(args.endpoint)
    if url.hostname not in ('127.0.0.1', 'localhost', '::1') or url.username or url.password or url.query or url.fragment:
        parser.error('This live fixture accepts a loopback endpoint without URL credentials only.')
    source = ROOT/'work/test-app/OShell.app'
    info = plistlib.loads((source/'Contents/Info.plist').read_bytes())
    if info.get('OShellTestHarness') is not True: parser.error('Build with bash scripts/build.sh --tests first.')
    key = getpass.getpass('AI live test key (hidden): ')
    report = ROOT/('validation/ui-ai-live-models.json' if args.models_only else 'validation/ui-ai-live.json'); report.unlink(missing_ok=True)
    with tempfile.TemporaryDirectory(prefix='ai-live-', dir=ROOT/'work') as directory:
        root = Path(directory); app = root/'OShell AI Live Test.app'; data = root/'data'; data.mkdir(mode=0o700)
        ssh = SSHFixture(data) if args.ssh else None
        # A real interactive zsh, isolated from user startup files and history.
        (data/'.zshenv').write_text('unsetopt GLOBAL_RCS\n')
        (data/'.zshrc').write_text("unset HISTFILE\nPROMPT='oshell-fixture%# '\nRPROMPT=''\n")
        subprocess.run(['ditto', str(source), str(app)], check=True)
        bundle = 'app.oshell.ai-live.' + uuid.uuid4().hex
        info.update(CFBundleIdentifier=bundle, CFBundleName='OShell AI Live Test', CFBundleDisplayName='OShell AI Live Test')
        info.pop('SUDefaultsDomain', None)
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
        environment = dict(os.environ, OSHELL_DATA_DIR=str(data), ZDOTDIR=str(data), OSHELL_AI_LIVE_OUTPUT=str(report))
        process = subprocess.Popen([str(app/'Contents/MacOS/OShell'), '--ai-live-test'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
        try:
            inputs = dict(endpoint=args.endpoint, model=args.model, apiKey=key)
            if args.models_only: inputs['modelsOnly'] = True
            if ssh: inputs['ssh'] = dict(port=ssh.port, username=ssh.username, password=ssh.password)
            payload = json.dumps(inputs).encode(); inputs.clear()
            # Never log process output: provider errors or platform diagnostics
            # must not accidentally expose credentials. Report only boolean checks.
            process.communicate(input=payload, timeout=360); payload = b''
            if process.returncode != 0: raise RuntimeError('Live test application exited unsuccessfully.')
            result = json.loads(report.read_text())
            if ssh: result['checks'].update(ssh.result())
            result['passed'] = all(result['checks'].values())
            report.write_text(json.dumps(result, ensure_ascii=False, indent=2))
            failures = [name for name, passed in result['checks'].items() if not passed]
            print(json.dumps({'passed': result['passed'], 'checkCount': len(result['checks']), 'failedChecks': failures, 'liveModel': args.model}, ensure_ascii=False))
            if failures or not result['passed']: raise RuntimeError('Live workflow failed; see validation/ui-ai-live.json (no key stored).')
        finally:
            key = ''; payload = b''
            if process.poll() is None:
                process.terminate()
                try: process.communicate(timeout=5)
                except subprocess.TimeoutExpired: process.kill(); process.communicate()
            subprocess.run(['defaults','delete',bundle], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if ssh: ssh.close()

if __name__ == '__main__': main()
