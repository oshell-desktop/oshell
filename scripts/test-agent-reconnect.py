#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Real STDIO helper + disposable Unix socket. No app, user tokens or SSH.

Usage: python3 scripts/test-agent-reconnect.py --helper /path/to/OShell-MCP
"""
import argparse
from collections import Counter, defaultdict, deque
import importlib.util
import json
import os
from pathlib import Path
import select
import shutil
import socket
import struct
import subprocess
import tempfile
import threading
import time


class Backend:
    def __init__(self, path):
        self.path = path
        self.counts = Counter()
        self.plans = defaultdict(deque)
        self.connections = set()
        self.lock = threading.Lock()
        self.errors = []
        self.start()

    def start(self):
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(self.path))
        listener.listen(8)
        listener.settimeout(.1)
        self.listener = listener
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self.accept, args=(listener, self.stop_event), daemon=True)
        self.thread.start()

    def accept(self, listener, stopped):
        while not stopped.is_set():
            try:
                connection, _ = listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            with self.lock:
                self.connections.add(connection)
            threading.Thread(target=self.serve, args=(connection,), daemon=True).start()

    @staticmethod
    def exact(connection, size):
        data = b''
        while len(data) < size:
            part = connection.recv(size - len(data))
            if not part:
                raise EOFError()
            data += part
        return data

    def serve(self, connection):
        try:
            while True:
                size, = struct.unpack('!I', self.exact(connection, 4))
                assert 0 < size <= 262144
                request = json.loads(self.exact(connection, size))
                assert request['credential'] == 'synthetic-reconnect-token'
                name = request['tool']
                with self.lock:
                    self.counts[name] += 1
                    action = self.plans[name].popleft() if self.plans[name] else 'ok'
                if callable(action):
                    action = action(connection)
                if action == 'drop':
                    return
                if action == 'bad-frame':
                    connection.sendall(struct.pack('!I', 262145))
                    return
                if action == 'bad-json':
                    connection.sendall(struct.pack('!I', 1) + b'{')
                    return
                response = action if isinstance(action, dict) else {'result': {'ok': True}}
                encoded = json.dumps(response).encode()
                connection.sendall(struct.pack('!I', len(encoded)) + encoded)
        except (EOFError, OSError):
            pass
        except Exception as error:
            self.errors.append(repr(error))
        finally:
            with self.lock:
                self.connections.discard(connection)
            connection.close()

    def plan(self, name, *actions):
        with self.lock:
            self.plans[name].extend(actions)

    def stop(self):
        self.stop_event.set()
        self.listener.close()
        self.thread.join(2)
        with self.lock:
            for connection in self.connections:
                try:
                    connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
        self.path.unlink(missing_ok=True)


class Client:
    def __init__(self, helper, path):
        env = dict(os.environ, OSHELL_AGENT_SOCKET=str(path), OSHELL_AGENT_TOKEN='synthetic-reconnect-token')
        self.process = subprocess.Popen([str(helper)], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, bufsize=0)
        self.counter = 0
        self.buffer = b''
        self.saved = {}
        assert 'result' in self.rpc('initialize', {'protocolVersion': '2025-11-25', 'capabilities': {},
                                                  'clientInfo': {'name': 'Reconnect fixture', 'version': '1'}})
        self.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})

    def send(self, value):
        self.process.stdin.write(json.dumps(value).encode() + b'\n')
        self.process.stdin.flush()

    def begin(self, method, params):
        self.counter += 1
        self.send({'jsonrpc': '2.0', 'id': self.counter, 'method': method, 'params': params})
        return self.counter

    def response(self, number):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if number in self.saved:
                return self.saved.pop(number)
            if b'\n' not in self.buffer:
                ready, _, _ = select.select([self.process.stdout], [], [], max(0, deadline - time.monotonic()))
                if not ready:
                    break
                data = os.read(self.process.stdout.fileno(), 65536)
                assert data, 'helper STDIO closed unexpectedly'
                self.buffer += data
                continue
            line, self.buffer = self.buffer.split(b'\n', 1)
            response = json.loads(line)
            if 'id' in response:
                self.saved[response['id']] = response
        raise TimeoutError('MCP response')

    def rpc(self, method, params):
        return self.response(self.begin(method, params))

    def tool(self, name, **arguments):
        result = self.rpc('tools/call', {'name': name, 'arguments': arguments})['result']
        text = result['content'][0]['text']
        return {'error': text} if result.get('isError') else json.loads(text)

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(3)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(3)


def run(helper):
    checks = []
    def check(name, passed):
        assert passed, name
        checks.append(name)

    spec = importlib.util.spec_from_file_location('installer', Path(__file__).with_name('install-local-app.py'))
    installer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(installer)
    with tempfile.TemporaryDirectory(prefix='oshell-reconnect-', dir='/tmp') as raw:
        root = Path(raw)
        target = root/'OShell.app'
        def stage(path):
            executable = path/'Contents/Helpers/OShell-MCP'
            executable.parent.mkdir(parents=True)
            shutil.copy2(helper, executable)
            main = path/'Contents/MacOS/OShell'
            main.parent.mkdir()
            main.write_text('synthetic app; never executed')
            return executable
        executable = stage(target)
        path = root/'control.sock'
        client = Client(executable, path)
        backend = None
        try:
            pid = client.process.pid
            check('offline initialize and tools/list', len(client.rpc('tools/list', {})['result']['tools']) == 8)
            check('offline call retains STDIO', 'error' in client.tool('sessions_list') and client.process.poll() is None)
            backend = Backend(path)
            check('service enabled after offline initialize', client.tool('sessions_list').get('ok'))
            for name, args in [('sessions_list', {}), ('session_state', {'session_id': 'fixture', 'include_screen': False}),
                               ('operation_read', {'operation_id': 'fixture', 'wait_ms': 0}),
                               ('operation_read', {'operation_id': 'fixture', 'wait_ms': 1000})]:
                before = backend.counts[name]
                backend.plan(name, 'drop')
                check(name + ' reconnect ' + str(args.get('wait_ms', '')), client.tool(name, **args).get('ok')
                      and backend.counts[name] == before + 2)
            for action in [{'error': 'unauthorized', 'result': None}, 'bad-frame', 'bad-json']:
                before = backend.counts['sessions_list']
                backend.plan('sessions_list', action)
                check('no replay of ' + str(action), 'error' in client.tool('sessions_list')
                      and backend.counts['sessions_list'] == before + 1)
            before = backend.counts['sessions_list']
            backend.plan('sessions_list', 'drop', 'drop')
            check('retry is bounded', 'error' in client.tool('sessions_list') and backend.counts['sessions_list'] == before + 2)
            check('next call still works', client.tool('sessions_list').get('ok'))
            backend.stop()
            backend.start()
            check('backend restart keeps same STDIO', client.tool('sessions_list').get('ok') and client.process.pid == pid)
            for name, args in [('session_exec', {'session_id': 'fixture', 'generation': 'fixture', 'command': 'pwd', 'idempotency_key': 'fixed'}),
                               ('command_submit', {'task_id': 'fixture', 'command': 'pwd', 'idempotency_key': 'fixed'}),
                               ('task_start', {'session_id': 'fixture', 'generation': 'fixture'}),
                               ('task_stop', {'task_id': 'fixture', 'interrupt': True}), ('task_end', {'task_id': 'fixture'})]:
                before = backend.counts[name]
                backend.plan(name, 'drop')
                result = client.tool(name, **args)
                check(name + ' never replayed after lost reply', '未自动重发' in result.get('error', '') and backend.counts[name] == before + 1)
            backend.stop()
            backend.start()
            check('known idle EOF reconnects before mutation', client.tool('task_start', session_id='fixture', generation='fixture').get('ok'))
            before = backend.counts['session_exec']
            backend.plan('session_exec', {'result': {'operation_id': 'receipt', 'state': 'running'}})
            backend.plan('operation_read', 'drop', 'drop')
            result = client.tool('session_exec', session_id='fixture', generation='fixture', command='pwd', idempotency_key='receipt')
            check('successful submission receipt survives read failure', result.get('operation_id') == 'receipt'
                  and result.get('read_error') and result.get('next_action') == 'read_output' and backend.counts['session_exec'] == before + 1)
            check('resume read by original receipt', client.tool('operation_read', operation_id='receipt').get('ok'))
            entered = threading.Event()
            closed = threading.Event()
            def hold(connection):
                entered.set()
                if connection.recv(1) == b'':
                    closed.set()
                return 'drop'
            before = backend.counts['operation_read']
            backend.plan('operation_read', hold)
            number = client.begin('tools/call', {'name': 'operation_read', 'arguments': {'operation_id': 'receipt', 'wait_ms': 1000}})
            assert entered.wait(3)
            client.send({'jsonrpc': '2.0', 'method': 'notifications/cancelled', 'params': {'requestId': number}})
            assert closed.wait(3)
            time.sleep(.35)  # exceeds retry delay: cancelled read must not reconnect
            check('cancelled wait does not retry', backend.counts['operation_read'] == before + 1)
            check('control channel survives cancellation', client.tool('sessions_list').get('ok'))
            old_inode = executable.stat().st_ino
            source = root/'stage/OShell.app'
            stage(source)
            check('publish while actual MCP helper runs', installer.publish(source, target, [str(executable)]) == target
                  and executable.stat().st_ino != old_inode)
            check('same initialized client survives binary replacement', client.tool('sessions_list').get('ok')
                  and client.process.pid == pid and client.process.poll() is None)
            backend.stop()
            backend.start()
            check('old mapped helper reconnects after replacement', client.tool('sessions_list').get('ok'))
            new_client = Client(executable, path)
            try:
                check('new client starts installed image', new_client.tool('sessions_list').get('ok'))
            finally:
                new_client.close()
            check('backend fixture healthy', not backend.errors)
        finally:
            client.close()
            if backend:
                backend.stop()
    print(json.dumps({'passed': len(checks), 'checks': checks}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', type=Path, required=True)
    run(parser.parse_args().helper.resolve(strict=True))
