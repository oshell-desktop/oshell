#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Exercise real font WebDAV transport on loopback with synthetic bytes only."""
import argparse, importlib.util, json, os, subprocess, threading
from http.server import ThreadingHTTPServer
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--checks', type=Path, default=ROOT/'work/build-tests/swift/release/OShellCoreChecks')
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location('dav_fixture', ROOT/'scripts/run-webdav-tests.py')
    fixture = importlib.util.module_from_spec(spec); spec.loader.exec_module(fixture)
    handler = fixture.DAV
    server = ThreadingHTTPServer(('127.0.0.1', 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        env = dict(os.environ, OSHELL_FONT_DAV=f'http://127.0.0.1:{server.server_port}/fonts-fixture/')
        subprocess.run([str(args.checks.resolve()), '--font-library-checks'], env=env, check=True, timeout=90)
        manifests = [(path, body) for path, body in handler.bodies.items() if path.endswith('/fonts/library.json')]
        assert len(manifests) == 1
        path, body = manifests[0]; manifest = json.loads(body)
        assert manifest['format'] == 'OShell.font-library' and len(manifest['fonts']) == 1
        asset = manifest['fonts'][0]
        blob = handler.bodies[path.removesuffix('library.json')+asset['sha256']+'.'+asset['extension']]
        assert blob[:4] == b'\0\1\0\0' and len(blob) == asset['size']
        assert all('/fonts/' in key for key in handler.bodies), 'must not touch vault or private files'
        print('PASS: actual DAV font upload/download, plaintext attachments, conditional writes; no private data')
    finally:
        server.shutdown(); server.server_close()

if __name__ == '__main__': main()
