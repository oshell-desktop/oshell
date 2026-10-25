#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Stateless loopback model verifies context on the actual HTTP requests."""
import importlib.util, json, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
requests, errors = [], []
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        text = json.dumps(payload, ensure_ascii=False); index = len(requests) + 1
        requests.append({'path': self.path, 'body': payload})
        try:
            assert self.headers['Authorization'] == 'Bearer synthetic-context-key'
            assert 'synthetic-context-key' not in text
            if index == 1: assert 'CTX_FIRST_REMEMBER_ALPHA' in text and 'CTX_ANSWER_' not in text
            if index in (2, 3):
                assert 'CTX_FIRST_REMEMBER_ALPHA' in text and 'CTX_ANSWER_1' in text
                if index == 3: assert 'CTX_SECOND_WHAT_DID_I_SAY' in text and 'CTX_ANSWER_2' in text
                assert any(m['role'] == 'assistant' for m in payload['messages'])
            if index == 4: assert 'CTX_FIRST_REMEMBER_ALPHA' not in text and all('CTX_ANSWER_'+str(n) not in text for n in (1, 2, 3))
            if index == 5: assert 'CTX_AFTER_CLEAR' in text and 'CTX_AFTER_REVOKE' not in text and 'CTX_SECOND' not in text
            if index == 6: assert 'CTX_OTHER_SESSION' in text and 'CTX_AFTER_CLEAR' not in text and 'CTX_ANSWER_' not in text
            if index == 7: assert self.path == '/b' and 'CTX_AFTER_CLEAR' not in text and 'CTX_OTHER_SESSION' not in text
            if index == 8: assert self.path == '/b' and 'CTX_OTHER_RECIPIENT' in text and 'CTX_ANSWER_7' in text and 'CTX_AFTER_CLEAR' not in text
            if index == 9: assert self.path == '/a' and all(s in text for s in ('CTX_AFTER_CLEAR', 'CTX_ANSWER_5', 'CTX_OTHER_RECIPIENT', 'CTX_ANSWER_7', 'CTX_RECIPIENT_FOLLOWUP', 'CTX_ANSWER_8')) and 'CTX_OTHER_SESSION' not in text
            if index == 10: assert 'CTX_NEW_CHAT' in text and 'CTX_ANSWER_' not in text and 'CTX_MERGE_RECIPIENT_CONTEXT' not in text
            assert index <= 10
            body = json.dumps({'choices':[{'finish_reason':'stop','message':{'role':'assistant','content':'CTX_ANSWER_'+str(index)}}]}).encode(); status = 200
        except Exception as error:
            errors.append(f'round {index}: {type(error).__name__}'); body=b'{}'; status=500
        self.send_response(status); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
def main():
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
    fixture=ROOT/'validation/ai-context-fixture.txt';fixture.parent.mkdir(exist_ok=True);fixture.write_text(f'http://127.0.0.1:{server.server_port}')
    try:
        spec=importlib.util.spec_from_file_location('ui_runner',ROOT/'scripts/run-ui-tests.py'); runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)
        runner.run_case(ROOT/'work/test-app/OShell.app','ai-context',120)
        assert not errors, errors
        assert len(requests)==10, len(requests)
        print('Context transport passed: 10 real requests; memory, roles, isolation, recipient consent, revocation and clear verified.')
    finally:
        fixture.unlink(missing_ok=True);server.shutdown();server.server_close()
        if errors: print(errors)
if __name__=='__main__': main()
