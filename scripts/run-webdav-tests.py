#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Isolated WebDAV fixtures; never contacts a real account or logs credentials/payloads."""
import base64, hashlib, json, plistlib, subprocess, tempfile, threading, uuid, os, re, signal
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import argparse, time
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
class DAV(BaseHTTPRequestHandler):
    bodies = {}
    collections = set()
    created = []
    guard = threading.Lock()
    def log_message(self, *_): pass
    def respond(self, status, body=b'', etag=None, length=None):
        self.send_response(status)
        self.send_header('Content-Length', str(len(body) if length is None else length))
        if etag is not None: self.send_header('ETag', etag)
        self.end_headers()
        if body:
            try: self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError): pass
    def allowed(self):
        expected = 'Basic ' + base64.b64encode(b'fixture:fixture-password').decode()
        if self.headers.get('Authorization') != expected:
            self.respond(401); return False
        return True
    def do_PROPFIND(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        if not self.allowed(): return
        folder = self.path.split('/')[1]
        if folder == 'denied': self.respond(403); return
        if folder == 'badxml': self.respond(207, b'<broken'); return
        if folder == 'race' and self.path not in self.collections: self.respond(404); return
        if folder not in ('existing', 'file', 'propdenied', 'wronghref') and self.path not in self.collections: self.respond(404); return
        resource = '' if folder == 'file' else '<d:collection/>'
        status = '403 Forbidden' if folder == 'propdenied' else '200 OK'
        href = '/unrelated/' if folder == 'wronghref' else self.path
        self.respond(207, ('<d:multistatus xmlns:d="DAV:"><d:response><d:href>'+escape(href)+'</d:href><d:propstat><d:prop><d:resourcetype>'+resource+'</d:resourcetype></d:prop><d:status>HTTP/1.1 '+status+'</d:status></d:propstat></d:response></d:multistatus>').encode())
    def do_MKCOL(self):
        if not self.allowed(): return
        folder = self.path.split('/')[1]
        with self.guard:
            self.created.append(self.path)
            if folder == 'mkdenied': self.respond(403); return
            if folder == 'missingparent': self.respond(409); return
            if folder == 'false405': self.respond(405); return
            existed = self.path in self.collections
            self.collections.add(self.path)
        self.respond(405 if existed or folder == 'race' else 201)
    def do_GET(self):
        if not self.allowed(): return
        folder = self.path.split('/')[1]
        if folder == 'redirect':
            self.send_response(302); self.send_header('Location', 'https://must-not-follow.example.test/private'); self.send_header('Content-Length', '0'); self.end_headers(); return
        if folder == 'offline': self.respond(503); return
        if folder == 'large': self.respond(200, etag='"large"', length=64 * 1024 * 1024); return
        if folder in ('noetag', 'weak'): self.respond(200, b'{}', etag=None if folder == 'noetag' else 'W/"weak"'); return
        with self.guard:
            body = self.bodies.get(self.path)
        if body is None: self.respond(404)
        else: self.respond(200, body, '"' + hashlib.sha256(body).hexdigest() + '"')
    def do_PUT(self):
        data = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        if not self.allowed(): return
        with self.guard:
            old = self.bodies.get(self.path)
            if old is None:
                accepted = self.headers.get('If-None-Match') == '*'
            else:
                accepted = self.headers.get('If-Match') == '"' + hashlib.sha256(old).hexdigest() + '"'
            if not accepted: self.respond(412); return
            self.bodies[self.path] = data
            if self.path == '/protocol/oshell/oshell-vault.json': self.bodies['/legacyroot/oshell-vault.json'] = data
        if self.path.startswith('/engine/'): time.sleep(0.6)  # Exercise edits/modal dialogs while a PUT is in flight.
        self.respond(201 if old is None else 204, etag='"' + hashlib.sha256(data).hexdigest() + '"')

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--flavor', choices=['arm64', 'legacy', 'both'], default='arm64'); args = parser.parse_args()
    (ROOT/'work').mkdir(exist_ok=True); (ROOT/'validation').mkdir(exist_ok=True)
    server = ThreadingHTTPServer(('127.0.0.1', 0), DAV); threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(dir=ROOT/'work', prefix='webdav-test-', ignore_cleanup_errors=True) as temp:
            base = Path(temp); interchange = base/'cross-architecture-vault.json'
            for flavor in (['arm64', 'legacy'] if args.flavor == 'both' else [args.flavor]):
                DAV.bodies.clear(); DAV.collections.clear(); DAV.created.clear()
                app = base/('OShell-'+flavor+'.app'); source = ROOT/('work/test-app/OShell.app' if flavor == 'arm64' else 'work/test-release/legacy/OShell.app')
                subprocess.run(['ditto', str(source), str(app)], check=True)
                info_path = app/'Contents/Info.plist'; info = plistlib.loads(info_path.read_bytes()); identity = 'app.oshell.webdav-test.'+uuid.uuid4().hex
                info.update(CFBundleIdentifier=identity, CFBundleName='OShell WebDAV Test', SUDefaultsDomain=identity); info_path.write_bytes(plistlib.dumps(info))
                subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
                config = base/('config-'+flavor); config.mkdir()
                report = ROOT/'validation'/('webdav-'+flavor+'.json'); log = report.with_suffix('.log')
                env = {'OSHELL_DATA_DIR':str(config), 'ZDOTDIR':str(config), 'OSHELL_DAV_TEST_SERVER':f'http://127.0.0.1:{server.server_port}/', 'OSHELL_DAV_OUTPUT':str(report)}
                if flavor == 'arm64': env['OSHELL_DAV_INTEROP_OUTPUT'] = str(interchange)
                elif interchange.exists(): env['OSHELL_DAV_INTEROP_INPUT'] = str(interchange)
                command = ['open', '-n', '-W']
                for key, value in env.items(): command += ['--env', key+'='+value]
                command += ['--stdout', str(log), '--stderr', str(log), str(app), '--args', '--webdav-test']
                try:
                    subprocess.run(command, check=True, timeout=180, capture_output=True)
                    result = json.loads(report.read_text())
                    print(flavor, len(result['checks']), 'checks; failures:', [k for k,v in result['checks'].items() if not v], flush=True)
                    assert result['passed']
                    assert DAV.created.count('/protocol/oshell/') == 1
                    assert '/existing/oshell/' not in DAV.created and not any(p.startswith('/legacyroot/') for p in DAV.created)
                    assert not any('/oshell/oshell/' in p for p in DAV.created)
                    assert '/race/oshell/' in DAV.collections
                    assert not any(p.startswith(('/file/', '/propdenied/', '/wronghref/', '/denied/', '/badxml/')) for p in DAV.created)
                    assert '/engine/oshell/oshell-vault.json' in DAV.bodies
                    assert '/engine/oshell-vault.json' not in DAV.bodies
                    assert all(json.loads(data)['format'] == 'OShell.shared-vault' for data in DAV.bodies.values())
                    startup = base/('startup-'+flavor); startup.mkdir()
                    (startup/'configuration.json').write_bytes((config/'configuration.json').read_bytes())
                    startup_report = ROOT/'validation'/('encrypted-startup-'+flavor+'.json')
                    subprocess.run(['open','-n','-W','--env','OSHELL_DATA_DIR='+str(startup),'--env','ZDOTDIR='+str(startup),'--env','OSHELL_STARTUP_VAULT_OUTPUT='+str(startup_report),'--stdout',str(log),'--stderr',str(log),str(app),'--args','--encrypted-startup-test'], check=True, timeout=80, capture_output=True)
                    startup_result = json.loads(startup_report.read_text())
                    print(flavor, 'encrypted startup:', startup_result['passed'], flush=True)
                    assert startup_result['passed']
                finally:
                    # Never leave a timed-out fixture application behind; match its exact temporary executable.
                    matches = subprocess.run(['pgrep', '-f', '^'+re.escape(str(app/'Contents/MacOS/OShell'))+'(?: |$)'], capture_output=True, text=True)
                    for pid in matches.stdout.split():
                        try: os.kill(int(pid), signal.SIGTERM)
                        except ProcessLookupError: pass
                    subprocess.run(['defaults', 'delete', identity], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    finally: server.shutdown(); server.server_close()
if __name__ == '__main__': main()
