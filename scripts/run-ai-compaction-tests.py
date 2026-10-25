#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Synthetic-only native permission, interruption and context compaction checks."""
import importlib.util
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
requests, errors = [], []

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        try:
            payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            route, kind = self.path.split('/')[1:3]
            content = json.dumps(payload, ensure_ascii=False)
            compact = 'OSHELL_CONTEXT_COMPACTION_V1' in content
            requests.append((kind, route, compact))
            assert 'tools' not in payload
            if compact:
                assert 'CURRENT_QUESTION' not in content
                assert 'ORIGINAL_0_' in content or 'SYNTHETIC_SUMMARY' in content
                assert 'ORIGINAL_11_' not in content
                reply = 'SYNTHETIC_SUMMARY: Goal retained. Evidence source-0. Interrupted work remains unverified.'
            else:
                assert all(marker in content for marker in ['SYNTHETIC_SUMMARY', 'ORIGINAL_11_', 'CURRENT_QUESTION'])
                assert 'ORIGINAL_0_' not in content
                reply = 'FOLLOWUP_OK'
            if route == 'fail':
                self.send_response(500); self.end_headers(); return
            if route == 'slow':
                time.sleep(1)
            if kind == 'chatCompletions':
                result = {'choices': [{'finish_reason': 'stop', 'message': {'role': 'assistant', 'content': reply}}]}
            elif kind == 'responses':
                result = {'status': 'completed', 'output': [{'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': reply}]}]}
            elif kind == 'anthropic':
                result = {'type': 'message', 'role': 'assistant', 'stop_reason': 'end_turn', 'content': [{'type': 'text', 'text': reply}]}
            else:
                result = {'candidates': [{'finishReason': 'STOP', 'content': {'role': 'model', 'parts': [{'text': reply}]}}]}
            body = json.dumps(result).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                assert route == 'slow'
        except Exception as error:
            errors.append(repr(error)); self.send_response(500); self.end_headers()

def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    fixture = ROOT / 'validation/ai-compaction-fixture.txt'
    fixture.parent.mkdir(exist_ok=True)
    fixture.write_text(f'http://127.0.0.1:{server.server_port}')
    try:
        spec = importlib.util.spec_from_file_location('runner', ROOT / 'scripts/run-ui-tests.py')
        runner = importlib.util.module_from_spec(spec); spec.loader.exec_module(runner)
        runner.run_case(ROOT / 'work/test-app/OShell.app', 'ai-compaction', 120)
        assert not errors, errors
        assert len([r for r in requests if not r[2]]) == 4, requests
        assert len([r for r in requests if r[1] == 'fail']) == 1, requests
        assert len([r for r in requests if r[1] == 'slow']) == 1, requests
        print('Four protocols: summary + recent turns, recipient isolation, revocation, failure and cancellation passed.')
    finally:
        fixture.unlink(missing_ok=True); server.shutdown(); server.server_close()
        if errors:
            print(errors)

if __name__ == '__main__':
    main()
