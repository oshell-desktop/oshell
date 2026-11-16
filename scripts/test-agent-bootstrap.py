#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Exercise the real Swift-generated loader in disposable Bash/Zsh PTYs, never SSH hosts."""
import argparse
import base64
import json
import os
import pty
import re
import select
import signal
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--helper', type=Path, required=True)
parser.add_argument('--shell', action='append')
parser.add_argument('--mode', action='append', choices=['success', 'timeout', 'partial', 'cancel', 'corrupt'])
parser.add_argument('--echo-report', type=Path)
args = parser.parse_args()
checks = []
echoes = []


def fixture():
    token = str(uuid.uuid4()).upper()
    data = json.loads(subprocess.check_output([str(args.helper.resolve()), '--agent-shell-fixture', token]))
    return token, data


class Shell:
    def __init__(self, shell, root):
        self.buffer = b''
        self.child, self.fd = pty.fork()
        if self.child == 0:
            os.chdir(root)
            env = dict(HOME=root, ZDOTDIR=root, PATH='/usr/bin:/bin:/opt/homebrew/bin', TERM='xterm-256color',
                       PS1='fixture> ', PROMPT='fixture> ', HISTFILE=root+'/history', HISTSIZE='100', LC_ALL='en_US.UTF-8')
            flags = ['--noprofile', '--norc', '-i'] if 'bash' in shell else ['-d', '-f', '-i']
            os.execve(shell, [shell] + flags, env)
        os.set_blocking(self.fd, False)
        self.until(b'fixture> ')

    def write(self, data):
        pending = data.encode() if isinstance(data, str) else data
        deadline = time.monotonic() + 5
        while pending:
            if time.monotonic() > deadline:
                raise TimeoutError('PTY write')
            readable, writable, _ = select.select([self.fd], [self.fd], [], .1)
            if readable:
                self.buffer += os.read(self.fd, 65536)
            if writable:
                pending = pending[os.write(self.fd, pending):]

    def until(self, marker, timeout=8):
        deadline = time.monotonic() + timeout
        while marker not in self.buffer:
            if time.monotonic() > deadline:
                raise AssertionError(f'missing {marker!r}: {self.buffer[-1500:]!r}')
            if select.select([self.fd], [], [], .1)[0]:
                self.buffer += os.read(self.fd, 65536)
        end = self.buffer.index(marker) + len(marker)
        result, self.buffer = self.buffer[:end], self.buffer[end:]
        return result

    def tty(self):
        self.write('command stty -g\n')
        output = self.until(b'fixture> ')
        output = re.sub(rb'\x1b\][^\x07]*\x07', b'', output)
        found = re.findall(rb'(?m)^((?:gfmt1:[^\r\n]+|[0-9a-f]+(?::[0-9a-f]+)+))\r?$', output)
        assert found, repr(output)
        return found[-1]

    def close(self):
        os.close(self.fd)
        try:
            os.kill(self.child, signal.SIGHUP)
        except ProcessLookupError:
            pass
        os.waitpid(self.child, 0)


for executable in args.shell or ['/bin/bash', '/bin/zsh', '/opt/homebrew/bin/bash']:
    if not Path(executable).exists():
        continue
    for mode in args.mode or ['success', 'timeout', 'partial', 'cancel', 'corrupt']:
        with tempfile.TemporaryDirectory(prefix='oshell-bootstrap-') as root:
            shell = Shell(executable, root)
            try:
                before = shell.tty()
                shell.write("trap 'builtin printf TRAP_KEPT' USR1\n")
                shell.until(b'fixture> ')
                token, data = fixture()
                shell.write(data['bootstrap'])
                echo = shell.until(f'\x1b]779;OSHELL;{token};load;0\x07'.encode())
                echoes.append(dict(shell=executable, command=data['bootstrap'].rstrip('\n'), output=base64.b64encode(echo).decode()))
                if mode == 'success':
                    transferred = b''
                    for index, frame in enumerate(data['payload'].splitlines(keepends=True)):
                        if index:
                            transferred += shell.until(f'\x1b]779;OSHELL;{token};load;{index}\x07'.encode())
                        shell.write(frame)
                    output = shell.until(f'\x1b]779;OSHELL;{token};ready\x07'.encode())
                    transferred += output
                    assert all(frame.encode() not in transferred for frame in data['payload'].splitlines()), 'payload echoed'
                    shell.until(b'fixture> ')
                    assert shell.tty() == before, 'tty not restored after load'
                    shell.write('trap\n')
                    traps = shell.until(b'fixture> ')
                    assert b'TRAP_KEPT' in traps and b'command stty' not in traps, 'parent traps changed'
                    shell.write('false\n')
                    shell.until(f'\x1b]779;OSHELL;{token};start\x07'.encode())
                    shell.until(f'\x1b]779;OSHELL;{token};end;1\x07'.encode())
                    shell.until(b'fixture> ')
                    new_token, new_data = fixture()
                    shell.write(new_data['bootstrap'])
                    reuse = shell.until(f'\x1b]779;OSHELL;{new_token};ready\x07'.encode())
                    assert f'\x1b]779;OSHELL;{new_token};load;0\x07'.encode() not in reuse, 'unnecessary payload reload'
                    shell.until(b'fixture> ')
                    shell.write('fc -l 1\n')
                    history = shell.until(b'fixture> ')
                    assert data['payload'].splitlines()[0][2:42].encode() not in history, 'payload entered shell history'
                else:
                    if mode == 'cancel':
                        shell.write(b'\x03')
                    elif mode in ['partial', 'corrupt']:
                        frame = data['payload'].splitlines(keepends=True)[0] if mode == 'partial' else ': invalid!base64\n'
                        shell.write(frame)
                        shell.until(f'\x1b]779;OSHELL;{token};load;1\x07'.encode())
                        if mode == 'corrupt':
                            shell.write(data['payload'].splitlines(keepends=True)[-1])
                    shell.until(b'fixture> ')
                    assert shell.tty() == before, 'tty not restored after '+mode
                    # Delayed transport frames must remain no-ops, never run the payload.
                    shell.write(data['payload'].splitlines(keepends=True)[0])
                    shell.until(b'fixture> ')
                    shell.write("builtin printf 'LATE_%s_END\\n' \"${__oshell_mcp_version-unset}\"\n")
                    shell.until(b'LATE_unset_END\r\n')
                checks.append(executable + ': ' + mode)
                print('PASS', checks[-1], flush=True)
            finally:
                shell.close()
print('PASS', len(checks), 'bootstrap PTY scenarios')
if args.echo_report:
    args.echo_report.write_text(json.dumps(echoes))
