#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Real HTTP/curl and HTTPS/URLSession Digest requests with synthetic credentials."""
import argparse, base64, datetime, hashlib, importlib.util, ipaddress, json, re, ssl, subprocess, tempfile, threading
from pathlib import Path
from http.server import ThreadingHTTPServer
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('dav', ROOT/'scripts/run-webdav-tests.py')
dav = importlib.util.module_from_spec(spec); spec.loader.exec_module(dav)

class DigestDAV(dav.DAV):
    # Keep the HTTP fixture's ETag, request-body and collection implementation.
    stale = set()
    attempts = {}
    authenticated = set()
    basic_leaks = 0
    redirected = 0
    def allowed(self):
        mode = self.path.split('/')[1]
        if mode == 'target':
            type(self).redirected += 1; self.respond(500); return False
        if mode == 'basic': return super().allowed()
        key = (self.server.server_port, self.command, self.path)
        self.attempts[key] = self.attempts.get(key, 0) + 1
        header = self.headers.get('Authorization', '')
        if header.startswith('Basic '): type(self).basic_leaks += 1
        fields = dict((m[0], re.sub(r'\\(.)', r'\1', m[1]) if m[1] else m[2]) for m in re.findall(r'(\w+)=(?:"((?:\\.|[^"])*)"|([^,\s]+))', header))
        algorithm = ('SHA-256' if 'sha256' in mode else 'MD5') + ('-SESS' if mode.endswith('-sess') else '')
        realm = 'fixture, "realm"' if mode == 'digest-quoted' else 'fixture-realm'
        qop = mode != 'digest-legacy'
        nonce = 'replacement-nonce' if key in self.stale else 'fixture-nonce'
        stale = mode == 'digest-stale' and header.startswith('Digest ') and key not in self.stale
        if stale: self.stale.add(key); nonce = 'replacement-nonce'
        valid = False
        if header.startswith('Digest ') and not stale and mode != 'digest-basic-only':
            h = lambda value: hashlib.new('sha256' if algorithm.startswith('SHA-256') else 'md5', value.encode()).hexdigest()
            ha1 = h('fixture:' + realm + ':fixture-password')
            if algorithm.endswith('-SESS'): ha1 = h(':'.join([ha1, nonce, fields.get('cnonce', '')]))
            response = h(':'.join([ha1, nonce] + ([fields.get('nc', ''), fields.get('cnonce', ''), 'auth'] if qop else []) + [h(self.command + ':' + self.path)]))
            valid = (fields.get('username') == 'fixture' and fields.get('realm') == realm
                     and fields.get('nonce') == nonce and fields.get('uri') == self.path
                     and fields.get('qop') == ('auth' if qop else None) and fields.get('response') == response
                     and fields.get('algorithm', 'MD5').upper() == algorithm
                     and fields.get('opaque') == 'fixture-opaque')
        if valid:
            self.authenticated.add((self.server.server_port, mode, self.command))
            if mode == 'digest-redirect':
                self.send_response(302); self.send_header('Location', f'http://127.0.0.1:{self.server.server_port}/target/')
                self.send_header('Content-Length', '0'); self.end_headers(); return False
            return True
        self.send_response(401)
        if mode in ('digest-basic-only', 'digest-mixed'): self.send_header('WWW-Authenticate', 'Basic realm="fixture-realm"')
        if mode != 'digest-basic-only':
            encoded_realm = realm.replace('"', '\\"')
            self.send_header('WWW-Authenticate', f'Digest realm="{encoded_realm}", nonce="{nonce}", algorithm={algorithm}, opaque="fixture-opaque"' + (', qop="auth,auth-int"' if qop else '') + (', stale=true' if stale else ''))
        body = b'Authentication required; synthetic challenge body.'
        self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
        return False

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--skip-build', action='store_true'); args = parser.parse_args()
    build = ROOT/'work/digest-check'; build.mkdir(parents=True, exist_ok=True)
    if not args.skip_build:
        common = ['swiftc', '-swift-version', '5', '-module-cache-path', str(build/'modules')]
        subprocess.run(common + ['-emit-library', '-emit-module', '-module-name', 'OShellCore', *map(str, sorted((ROOT/'Sources/OShellCore').glob('*.swift'))), '-o', str(build/'libOShellCore.dylib'), '-emit-module-path', str(build/'OShellCore.swiftmodule')], check=True)
        subprocess.run(common + ['-I', str(build), '-L', str(build), '-lOShellCore', '-Xlinker', '-rpath', '-Xlinker', str(build), str(ROOT/'scripts/webdav-digest-check.swift'), '-o', str(build/'check')], check=True)
    with tempfile.TemporaryDirectory(prefix='oshell-digest-') as folder:
        root = Path(folder); servers = []
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'Digest synthetic fixture')])
        now = datetime.datetime.now(datetime.timezone.utc)
        certificate = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject).public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now-datetime.timedelta(days=1)).not_valid_after(now+datetime.timedelta(days=1))
            .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address('127.0.0.1'))]), critical=False)
            .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
            .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False).sign(key, hashes.SHA256()))
        cert = root/'cert.pem'; private = root/'key.pem'
        cert.write_bytes(certificate.public_bytes(serialization.Encoding.PEM)); private.touch(mode=0o600)
        private.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        fixture = {'certificate': base64.b64encode(certificate.public_bytes(serialization.Encoding.DER)).decode()}
        try:
            for scheme in ['http', 'https']:
                # Each scheme gets independent remote storage.
                handler = type(scheme+'DAV', (DigestDAV,), {'bodies': {}, 'collections': set(), 'created': [], 'writes': []})
                server = ThreadingHTTPServer(('127.0.0.1', 0), handler)
                if scheme == 'https':
                    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(cert, private)
                    server.socket = context.wrap_socket(server.socket, server_side=True)
                threading.Thread(target=server.serve_forever, daemon=True).start(); servers.append(server)
                fixture[scheme] = f'{scheme}://127.0.0.1:{server.server_port}/'
            urls = root/'urls.json'; urls.write_text(json.dumps(fixture))
            report = ROOT/'validation/webdav-digest.json'; report.parent.mkdir(exist_ok=True)
            subprocess.run([str(build/'check'), str(urls), str(report)], check=True, timeout=180)
            for server in servers:
                handler = server.RequestHandlerClass
                assert handler.basic_leaks == handler.redirected == 0
                assert not any('/digest-wrong/' in p or '/digest-basic-only/' in p for p in handler.writes)
                for mode in ['digest-md5', 'digest-sha256', 'digest-md5-sess', 'digest-sha256-sess', 'digest-legacy', 'digest-quoted', 'digest%20path', 'digest-stale', 'digest-mixed']:
                    assert all((server.server_port, mode, method) in handler.authenticated for method in ['GET', 'PUT', 'PROPFIND', 'MKCOL'])
            assert max(DigestDAV.attempts.values()) < 20, 'authentication retry loop'
            print('PASS: HTTP/HTTPS Digest, Basic compatibility, stale nonce, conditional writes, no Basic fallback, no redirect credentials')
        finally:
            for server in servers: server.shutdown(); server.server_close()

if __name__ == '__main__': main()
