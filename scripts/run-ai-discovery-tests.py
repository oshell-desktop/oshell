#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Native model-list discovery; all credentials and responses are synthetic."""
import importlib.util, json, threading, time
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit, parse_qs

ROOT = Path(__file__).resolve().parent.parent
requests, errors = [], []

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_POST(self):
        errors.append('Unexpected POST'); self.send_response(500); self.end_headers()
    def do_GET(self):
        url = urlsplit(self.path); group = url.path.split('/')[1]; query = parse_qs(url.query)
        requests.append(url.path)
        status, headers = 200, {}
        body = {'data': [{'id': 'model-one', 'display_name': 'Model One'}, {'id': 'model-two', 'display_name': 'Model Two'}, {'id': 'model-one'}, {'id': 'invalid\nmodel'}]}
        try:
            assert int(self.headers.get('Content-Length', '0')) == 0
            assert self.headers.get('Cookie') is None and self.headers.get('User-Agent', '').startswith('OShell/')
            auth = 'x-api-key' if group in ['anthropic', 'cycle'] else 'x-goog-api-key' if group == 'gemini' else 'Authorization'
            assert self.headers.get(auth) == ('Bearer ' if auth == 'Authorization' else '') + 'synthetic-discovery-key'
            assert all(self.headers.get(name) is None for name in ['Authorization', 'x-api-key', 'x-goog-api-key'] if name != auth)
            assert 'key' not in query and 'synthetic-discovery-key' not in self.path
            if group in ['anthropic', 'cycle']:
                assert self.headers.get('anthropic-version') == '2023-06-01'
                assert query.get('limit') == ['100'] and set(query).issubset({'limit', 'after_id'})
                more = group == 'cycle' or 'after_id' not in query
                body = {'data': [{'id': 'model-one', 'display_name': 'Model One'}] if more else [{'id': 'model-one'}, {'id': 'model-two'}], 'has_more': more, 'last_id': 'model-one'}
            elif group == 'gemini':
                assert query.get('pageSize') == ['100'] and set(query).issubset({'pageSize', 'pageToken'})
                if 'pageToken' not in query:
                    body = {'models': [{'name': 'models/gemini-one', 'displayName': 'Gemini One', 'supportedGenerationMethods': ['generateContent']}, {'name': 'models/embedding', 'supportedGenerationMethods': ['embedContent']}], 'nextPageToken': 'page two&x=y'}
                else:
                    assert query['pageToken'] == ['page two&x=y']
                    body = {'models': [{'name': 'models/gemini-two', 'supportedGenerationMethods': ['generateContent']}]}
            else: assert not query
            if group == 'unauthorized': status, body = 401, {'error': 'SERVER_SECRET_NEVER synthetic-discovery-key'}
            elif group == 'unsupported': status = 404
            elif group == 'redirect': status = 302; headers['Location'] = f'http://127.0.0.1:{self.server.server_port}/sink'
            elif group == 'slow': time.sleep(.45)
            elif group not in ['openai', 'responses', 'anthropic', 'cycle', 'gemini', 'ui', 'malformed', 'oversize']:
                raise AssertionError('Unexpected destination')
        except Exception as error:
            errors.append(group + ':' + type(error).__name__); status, body = 500, {}
        data = json.dumps(body).encode()
        if group == 'malformed': data = b'SERVER_SECRET_NEVER not json'
        if group == 'oversize': data = b'x' * (2 * 1024 * 1024 + 1)
        try:
            self.send_response(status)
            for name, value in headers.items(): self.send_header(name, value)
            self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError): pass

def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    fixture = ROOT/'validation/ai-discovery-fixture.txt'; fixture.write_text(f'http://127.0.0.1:{server.server_port}')
    try:
        spec = importlib.util.spec_from_file_location('ui_runner', ROOT/'scripts/run-ui-tests.py')
        runner = importlib.util.module_from_spec(spec); spec.loader.exec_module(runner)
        runner.run_case(ROOT/'work/test-app/OShell.app', 'ai-model-discovery', 120)
        assert not errors, errors
        counts = Counter(requests)
        assert counts['/anthropic/v1/models'] == 2 and counts['/gemini/v1beta/models'] == 2
        assert counts['/cycle/v1/models'] == 2 and counts['/ui/v1/models'] == 2
        assert not any('/sink' in path or '/changed/' in path for path in requests)
        report = {'passed': True, 'requests': dict(counts), 'checks': {'GETOnlyNoBody': True, 'onlyCurrentChannelKey': True, 'noKeyInURL': True, 'noRedirectOrFallback': True, 'boundedPagination': True}}
        (ROOT/'validation/ai-model-discovery-transport.json').write_text(json.dumps(report, indent=2)+'\n')
        print('Model discovery transport checks passed:', len(requests), 'GET requests')
    finally:
        fixture.unlink(missing_ok=True); server.shutdown(); server.server_close()

if __name__ == '__main__': main()
