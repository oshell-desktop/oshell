#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Bound SDK tasks with a stalled, synthetic Unix peer; no terminal or model is used."""
import argparse
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', type=Path, default=ROOT/'work/test-app/OShell.app/Contents/Helpers/OShell-MCP')
    args = parser.parse_args()
    checks = {}
    with tempfile.TemporaryDirectory(prefix='oshell-mcp-budget-', dir='/tmp') as root:
        path = str(Path(root)/'control.sock')
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(path); listener.listen(1); listener.settimeout(5)
        env = dict(os.environ, OSHELL_AGENT_SOCKET=path, OSHELL_AGENT_TOKEN='synthetic-resource-test')
        child = subprocess.Popen([str(args.helper)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, bufsize=0)
        peer = None
        try:
            def send(value):
                child.stdin.write(json.dumps(value).encode()+b'\n')

            def reply():
                result = bytearray()
                deadline = time.monotonic()+5
                while time.monotonic() < deadline:
                    if not select.select([child.stdout], [], [], max(0, deadline-time.monotonic()))[0]: break
                    byte = child.stdout.read(1)
                    if byte == b'\n': return json.loads(result)
                    if not byte: break
                    result.extend(byte)
                raise TimeoutError('MCP reply')

            send(dict(jsonrpc='2.0', id=1, method='initialize', params=dict(protocolVersion='2025-11-25', capabilities={}, clientInfo=dict(name='resource-fixture', version='1'))))
            checks['initialized'] = 'result' in reply()
            send(dict(jsonrpc='2.0', method='notifications/initialized'))
            # Responses replenish the budget: more than eight sequential calls must work.
            for number in range(2, 34):
                send(dict(jsonrpc='2.0', id=number, method='ping'))
                assert reply().get('id') == number
            checks['completedRequestsReleaseBudget'] = True
            # Space requests apart so the SDK drains its input queue; the first IPC request
            # deliberately never receives a reply. An input-buffer limit alone cannot help.
            for number in range(100, 108):
                send(dict(jsonrpc='2.0', id=number, method='tools/call', params=dict(name='sessions_list', arguments={})))
                if number == 100: peer, _ = listener.accept()
                time.sleep(.08)
            checks['eightInflightRequestsAllowed'] = child.poll() is None
            send(dict(jsonrpc='2.0', id=108, method='tools/call', params=dict(name='sessions_list', arguments={})))
            child.wait(timeout=5)
            checks['ninthInflightRequestClosesHelper'] = child.returncode == 0
        finally:
            if peer is not None: peer.close()
            listener.close()
            if child.poll() is None:
                child.terminate()
                try: child.wait(timeout=3)
                except subprocess.TimeoutExpired: child.kill(); child.wait()
            for stream in (child.stdin, child.stdout, child.stderr): stream.close()
    result = dict(passed=all(checks.values()), checks=checks)
    (ROOT/'validation/agent-mcp-resources.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result, indent=2))
    if not result['passed']: raise SystemExit(1)


if __name__ == '__main__': main()
