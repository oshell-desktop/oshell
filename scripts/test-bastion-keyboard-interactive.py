#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Real loopback challenges through the packaged SSH client, askpass, broker and vault."""
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading

import paramiko

APP = Path(__file__).resolve().parents[1] / 'work/test-app/OShell.app/Contents/MacOS/OShell'
USER = 'fixture#UTF-8#2437#SSH#root'
PASSWORD = ('Password:', False)
OTP = ('Verification code:', False)
MANUAL = 'fixture-manual'
SAVED = 'fixture-gateway'
KEY = paramiko.RSAKey.generate(2048)


class Server(paramiko.ServerInterface):
    def __init__(self, scenario, title, description, rounds):
        self.scenario = scenario
        self.title = title
        self.description = description
        self.rounds = iter(rounds)
        self.received = []
        self.executed = threading.Event()

    def get_allowed_auths(self, user):
        return 'password,keyboard-interactive' if self.scenario == 'partial' and not self.received else 'keyboard-interactive'

    def check_auth_password(self, user, password):
        self.received.append(password)
        return paramiko.AUTH_PARTIALLY_SUCCESSFUL

    def question(self):
        prompts = next(self.rounds, None)
        if prompts is None:
            return paramiko.AUTH_SUCCESSFUL
        return paramiko.InteractiveQuery(self.title, self.description, *prompts)

    def check_auth_interactive(self, user, submethods):
        expected = USER.replace('fixture', 'other') if self.scenario == 'other-user' else USER
        return self.question() if user == expected else paramiko.AUTH_FAILED

    def check_auth_interactive_response(self, responses):
        self.received.extend(responses)
        if self.scenario == 'retry' and len(self.received) == 1:
            return paramiko.AUTH_FAILED
        return self.question()

    def check_channel_request(self, kind, chanid):
        return paramiko.OPEN_SUCCEEDED if kind == 'session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_pty_request(self, *args):
        return True

    def check_channel_shell_request(self, channel):
        self.executed.set()
        return self.scenario == 'target-login'

    def check_channel_exec_request(self, channel, command):
        self.executed.set()
        return True


def serve(listener, server):
    sock, _ = listener.accept()
    with paramiko.Transport(sock) as ssh:
        ssh.add_server_key(KEY)
        ssh.start_server(server=server)
        channel = ssh.accept(8)
        if channel is None or not server.executed.wait(5):
            return
        if server.scenario == 'target-login':
            channel.settimeout(5)
            channel.sendall(b'\x1b[2J\x1b[H\r\r\n\x1b[32mLogin:\x1b[0m  root \r\r\n')
            channel.sendall(b'Password: ')
            answer = b''
            while b'\r' not in answer and len(answer) < 256:
                chunk = channel.recv(256)
                if not chunk:
                    break
                answer += chunk
            server.received.append('target' if answer == b'fixture-target\r' else 'unexpected')
        channel.send_exit_status(0)
        channel.shutdown_write()
        channel.close()


def check(scenario, rounds, expected, title='', description=''):
    with tempfile.TemporaryDirectory(prefix='oshell-bastion-', dir='/tmp') as folder, socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen(1)
        port = listener.getsockname()[1]
        server = Server(scenario, title, description, rounds)
        (Path(folder) / 'known_hosts').write_text(f'[127.0.0.1]:{port} {KEY.get_name()} {KEY.get_base64()}\n')
        skip = scenario in ['ordinary', 'external']
        if not skip:
            thread = threading.Thread(target=serve, args=(listener, server), daemon=True)
            thread.start()
        result = subprocess.run([APP, '--bastion-auth-test', str(port), scenario],
                                env=dict(os.environ, OSHELL_DATA_DIR=folder), capture_output=True, text=True, timeout=20)
        if result.returncode:
            raise RuntimeError(f'{scenario}: {result.stderr}')
        if not skip:
            thread.join(5)
            assert not thread.is_alive(), scenario
            actual = ['saved' if x == SAVED else 'manual' if x == MANUAL else 'unexpected' for x in server.received]
            assert server.received == expected, (scenario, actual)
            assert result.stdout.strip() == f'manual={expected.count(MANUAL)}', scenario
        print(f'PASS {scenario}')


if __name__ == '__main__':
    check('password', [[PASSWORD]], [SAVED])
    check('target-login', [[PASSWORD]], [SAVED, 'target'])
    check('keychain', [[PASSWORD]], [SAVED])
    check('password-otp', [[('Password: ', False)], [OTP]], [SAVED, MANUAL])
    check('otp-first', [[OTP], [PASSWORD]], [MANUAL, MANUAL])
    check('title', [[PASSWORD]], [MANUAL], title='Login')
    check('instructions', [[PASSWORD]], [MANUAL], description='Enter passcode')
    check('echo', [[('Password:', True)]], [MANUAL])
    check('multiple', [[PASSWORD, OTP]], [MANUAL, MANUAL])
    check('empty-round', [[], [PASSWORD]], [MANUAL])
    check('retry', [[PASSWORD], [PASSWORD]], [SAVED, MANUAL])
    check('partial', [[PASSWORD]], [SAVED, MANUAL])
    check('other-user', [[PASSWORD]], [MANUAL])
    check('removed', [[PASSWORD]], [MANUAL])
    check('external', [], [])
    check('ordinary', [], [])
