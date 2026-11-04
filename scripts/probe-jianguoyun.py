#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Probe conditional updates in an existing, dedicated Nutstore test directory.

For --native-sync build the real transport helper from the OShell checkout:
    swiftc -swift-version 5 Sources/OShellCore/*.swift Tests/NutstoreLive/main.swift -o work/nutstore-live-check
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import base64
import getpass
import http.client
import json
import subprocess
from pathlib import Path
from urllib.parse import quote
from threading import Barrier
from uuid import uuid4
from xml.etree import ElementTree as ET


def move_race(base, request):
    paths = [base + 'oshell-probe-' + uuid4().hex + suffix for suffix in ('.a', '.b', '.winner')]
    if any(request('GET', url)[0] != 404 for url in paths):
        raise RuntimeError('随机测试路径未返回 404。')
    bodies = [uuid4().bytes, uuid4().bytes]
    try:
        for url, value in zip(paths, bodies):
            if request('PUT', url, value, {'If-None-Match': '*'})[0] != 201:
                raise RuntimeError('临时文件创建失败。')
        barrier = Barrier(2)
        def publish(source):
            barrier.wait(timeout=10)
            return request('MOVE', source, headers={'Destination': 'https://dav.jianguoyun.com' + paths[-1], 'Overwrite': 'F'})[0]
        with ThreadPoolExecutor(max_workers=2) as pool:
            codes = list(pool.map(publish, paths[:2]))
        winners = [value for code, value in zip(codes, bodies) if code == 201]
        return {'status': codes, 'winner_preserved': len(winners) == 1 and any(v in (409, 412) for v in codes) and request('GET', paths[-1])[2] == winners[0]}
    finally:
        for url in paths:
            if request('DELETE', url)[0] not in (200, 204, 404):
                print('请清理测试文件', url.rsplit('/', 1)[-1])


def directory_path(directory):
    parts = directory.strip('/').split('/')
    if len(parts) < 2 or parts[0] != 'dav' or any(p in ('', '.', '..') for p in parts):
        raise ValueError('请输入 /dav/ 下已有的独立测试子目录。')
    return '/' + '/'.join(map(quote, parts)) + '/'

def probe(directory, request):
    base = directory_path(directory)
    name = 'oshell-probe-' + uuid4().hex + '.json'
    path = base + name
    original, newer, stale = b'{"probe":1}', b'{"probe":2}', b'{"probe":3}'
    if request('GET', path)[0] != 404:
        raise RuntimeError('新文件路径未返回 404，已停止。')
    status = request('PUT', path, original, {'If-None-Match': '*'})[0]
    if status != 201:
        raise RuntimeError(f'创建合成文件未返回 201 (HTTP {status})，已停止。测试文件名为 {name}')
    results = {}
    try:
        status, headers, body = request('GET', path)
        if status != 200 or body != original:
            raise RuntimeError('无法读回刚创建的合成文件。')
        raw = headers.get('etag', '')
        results['get_tag'] = 'missing' if not raw else 'weak' if raw.startswith('W/') else 'quoted' if raw.startswith('"') else 'bare'
        status, _, xml = request('PROPFIND', path, b'<d:propfind xmlns:d="DAV:"><d:prop><d:getetag/></d:prop></d:propfind>',
                                 {'Depth': '0', 'Content-Type': 'application/xml'})
        results['propfind'] = status
        # Every write below targets only this run's random file, even if the server ignores conditions.
        results['create_collision'] = request('PUT', path, stale, {'If-None-Match': '*'})[0]
        before = request('GET', path)[2]
        results['wrong_if_match'] = request('PUT', path, original, {'If-Match': '"' + uuid4().hex + '"'})[0]
        results['wrong_match_preserved_data'] = request('GET', path)[2] == before
        if status == 207:
            tags = ET.fromstring(xml).findall('.//{DAV:}getetag')
            prop = next(((tag.text or '').strip() for tag in tags if tag.text), '')
            results['property_tag'] = 'missing' if not prop else 'weak' if prop.startswith('W/') else 'quoted' if prop.startswith('"') else 'bare'
        if raw and not raw.startswith('W/') and results['wrong_if_match'] == 412 and results['wrong_match_preserved_data']:
            for mode in (['quoted', 'bare'] if results['get_tag'] == 'bare' else ['quoted']):
                # Start each trial from the current server version, including after a rejected creation.
                _, current, _ = request('GET', path)
                candidate = current['etag'].strip('"')
                if mode == 'quoted': candidate = '"' + candidate + '"'
                start = Barrier(2)
                def write(body):
                    start.wait(timeout=10)
                    return request('PUT', path, body, {'If-Match': candidate})[0]
                values = [uuid4().hex.encode(), uuid4().hex.encode()]
                with ThreadPoolExecutor(max_workers=2) as pool:
                    statuses = list(pool.map(write, values))
                winners = [value for value, code in zip(values, statuses) if code in (200, 204)]
                results[mode + '_racing_if_match'] = statuses
                results[mode + '_preserved_winner'] = len(winners) == 1 and 412 in statuses and request('GET', path)[2] == winners[0]
        source = path + '.stage'
        second_source = path + '.second-stage'
        destination = path + '.new'
        if any(request('GET', url)[0] != 404 for url in (source, second_source, destination)):
            raise RuntimeError('临时 MOVE 文件名已被占用。')
        move_headers = {'Destination': 'https://dav.jianguoyun.com' + destination, 'Overwrite': 'F'}
        if request('PUT', source, original, {'If-None-Match': '*'})[0] == 201:
            try:
                results['move_create'] = request('MOVE', source, headers=move_headers)[0]
                if results['move_create'] == 201:
                    if request('PUT', second_source, newer, {'If-None-Match': '*'})[0] in (200, 201, 204):
                        results['move_collision'] = request('MOVE', second_source, headers=move_headers)[0]
                        results['move_preserved_destination'] = request('GET', destination)[2] == original
            finally:
                for url in (source, second_source, destination):
                    if request('DELETE', url)[0] not in (200, 204, 404):
                        print('请清理本次测试文件', url.rsplit('/', 1)[-1])
        lockinfo = b'<d:lockinfo xmlns:d="DAV:"><d:lockscope><d:exclusive/></d:lockscope><d:locktype><d:write/></d:locktype></d:lockinfo>'
        status, headers, lock_xml = request('LOCK', path, lockinfo, {'Content-Type': 'application/xml', 'Timeout': 'Second-60', 'Depth': '0'})
        results['lock'] = status
        token = headers.get('lock-token', '')
        if status == 200 and not token and lock_xml:
            try:
                uri = ET.fromstring(lock_xml).findtext('.//{DAV:}locktoken/{DAV:}href')
                if uri:
                    token = '<' + uri.strip() + '>'
            except ET.ParseError:
                pass
        token = token.strip()
        if token and '<' not in token and '>' not in token:
            token = '<' + token + '>'
        results['lock_token_present'] = bool(token)
        if status == 200 and token.startswith('<') and token.endswith('>') and token.isascii() and not any(c.isspace() for c in token):
            try:
                before = request('GET', path)[2]
                results['competing_lock'] = request('LOCK', path, lockinfo, {'Content-Type': 'application/xml', 'Depth': '0', 'Timeout': 'Second-60'})[0]
                results['unlocked_writer'] = request('PUT', path, stale)[0]
                results['lock_preserved_data'] = request('GET', path)[2] == before
                results['lock_owner_write'] = request('PUT', path, newer, {'If': '(' + token + ')'})[0]
            finally:
                results['unlock'] = request('UNLOCK', path, headers={'Lock-Token': token})[0]
            results['expired_owner_write'] = request('PUT', path, stale, {'If': '(' + token + ')'})[0]
            results['expired_token_preserved_data'] = request('GET', path)[2] == newer
        # MKCOL is a separate namespace operation. Record whether two simultaneous
        # creators actually get exclusive ownership, independent of PUT semantics.
        gate = path + '.gate/'
        if request('PROPFIND', gate, headers={'Depth': '0'})[0] == 404:
            start = Barrier(2)
            def mkdir(_):
                start.wait(timeout=10)
                return request('MKCOL', gate)[0]
            with ThreadPoolExecutor(max_workers=2) as pool:
                results['racing_mkcol'] = list(pool.map(mkdir, range(2)))
            if 201 in results['racing_mkcol']:
                results['gate_cleanup'] = request('DELETE', gate)[0]
        return results
    finally:
        if request('DELETE', path)[0] not in (200, 204, 404):
            print('请在测试目录内清理本次合成文件', name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', help='existing dedicated directory, e.g. /dav/oshell-test/')
    parser.add_argument('--report', type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--move-only', action='store_true')
    mode.add_argument('--native-sync', action='store_true')
    args = parser.parse_args()
    user = input('坚果云账号：').strip()
    password = getpass.getpass('坚果云应用密码（不回显）：')
    auth = 'Basic ' + base64.b64encode((user + ':' + password).encode()).decode()

    def request(method, path, body=None, headers=None):
        conn = http.client.HTTPSConnection('dav.jianguoyun.com', timeout=30)
        try:
            conn.request(method, path, body, {'Authorization': auth, 'Accept-Encoding': 'identity', **(headers or {})})
            response = conn.getresponse()
            return response.status, {k.lower(): v for k, v in response.getheaders()}, response.read(65536)
        finally:
            conn.close()

    if args.native_sync:
        helper = Path(__file__).resolve().parents[1] / 'work/nutstore-live-check'
        if not helper.is_file():
            parser.error('请先编译 Tests/NutstoreLive/main.swift。')
        root = directory_path(args.directory) + 'oshell-probe-' + uuid4().hex + '/'
        folder = root + 'oshell/'
        def save(checks):
            if args.report:
                args.report.write_text(json.dumps(checks, ensure_ascii=False, indent=2) + '\n')
        checks = {'native_client_settings_and_race': False}
        save(checks)
        checks['preflight_http'] = request('PROPFIND', root, headers={'Depth': '0'})[0]
        save(checks)
        if checks['preflight_http'] != 404:
            raise RuntimeError('无法确认新的独立验收目录不存在。')
        checks['create_directory_http'] = request('MKCOL', root)[0]
        save(checks)
        if checks['create_directory_http'] != 201:
            raise RuntimeError('无法创建独立的验收目录。')
        try:
            config = {'address': 'https://dav.jianguoyun.com' + folder, 'username': user, 'password': password}
            done = subprocess.run([str(helper)], input=json.dumps(config).encode(), stdout=subprocess.PIPE, timeout=180)
            checks['helper_exit'] = done.returncode
            if done.returncode == 0:
                checks['observed'] = json.loads(done.stdout)
                checks['native_client_settings_and_race'] = True
            save(checks)
        finally:
            # This invocation created the random directory and populated it only with synthetic data.
            checks_cleanup = request('DELETE', root)[0]
            checks['cleanup_http'] = checks_cleanup
            save(checks)
            if checks_cleanup not in (200, 204, 404):
                print('请清理本次随机验收目录', root.rsplit('/', 2)[-2])
    elif args.move_only:
        checks = [move_race(directory_path(args.directory), request) for _ in range(3)]
    else:
        checks = probe(args.directory, request)
    result = json.dumps(checks, ensure_ascii=False, indent=2)
    if args.report:
        args.report.write_text(result + '\n')
    print(result)
    if args.native_sync and not checks['native_client_settings_and_race']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
