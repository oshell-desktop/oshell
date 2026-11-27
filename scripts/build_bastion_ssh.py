#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build the askpass-aware OpenSSH client from verified local source archives."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ARCHIVES = {
    "libressl-4.4.1": "290cdf1b53c086255dc302f118b98602a444e9ae6d11e9bfdd8c9b1b60aa3a22",
    "openssh-10.6p2": "9ae44872090cf2f06b3cf9ff147e7f16f309671340763ed2f99248398ae29d5b",
}


def build(work, arch, minimum, contents):
    base = work.resolve() / f'bastion-ssh-{arch}-{minimum}'
    base.mkdir(parents=True, exist_ok=True)
    flags = f'-Os -arch {arch} -mmacosx-version-min={minimum} -ffile-prefix-map={base}=/OShell'
    env = dict(os.environ, PATH='/usr/bin:/bin:/usr/sbin:/sbin', CC='clang', CFLAGS=flags,
               LDFLAGS=f'-arch {arch} -mmacosx-version-min={minimum}')
    crypto, ssh = (base / name for name in ARCHIVES)
    patch = ROOT / 'Vendor/openssh-bastion-askpass.patch'
    fingerprint = hashlib.sha256(patch.read_bytes() + Path(__file__).read_bytes()).hexdigest()
    stamp = base / '.recipe'
    if not stamp.exists() or stamp.read_text() != fingerprint or not (ssh / 'ssh').is_file():
        for name, digest in ARCHIVES.items():
            archive = ROOT / 'Vendor' / (name + '.tar.gz')
            if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
                raise ValueError(f'Unexpected source checksum for {name}')
            if (base / name).exists():
                shutil.rmtree(base / name)
            subprocess.run(['tar', '-xzf', archive, '-C', base], check=True)
        def run(cwd, *args):
            subprocess.run(args, cwd=cwd, env=env, check=True)
        host = ('aarch64' if arch == 'arm64' else arch) + '-apple-darwin'
        run(crypto, './configure', '--prefix=/usr', '--disable-shared', '--disable-tests', '--enable-static', '--host=' + host)
        run(crypto, 'make', '-C', 'crypto', '-j8')
        run(ssh, 'patch', '-p1', '-i', patch)
        env.update(CPPFLAGS=f'-I{crypto}/include', LIBS='-framework GSS', PKGCONFIG='no')
        env['LDFLAGS'] += f' -L{crypto}/crypto/.libs'
        run(ssh, './configure', '--prefix=/usr', '--sysconfdir=/etc/ssh', '--libexecdir=/usr/libexec',
            '--with-kerberos5=/usr', '--host=' + host)
        run(ssh, 'make', '-j8', 'ssh')
        stamp.write_text(fingerprint)
    shutil.copy2(ssh / 'ssh', contents / 'Helpers/OShell-SSH')
    for source, name in [(ssh / 'LICENCE', 'OpenSSH'), (crypto / 'COPYING', 'LibreSSL')]:
        shutil.copy2(source, contents / 'Resources' / (name + '-LICENSE.txt'))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('work', type=Path)
    parser.add_argument('arch', choices=['arm64', 'x86_64'])
    parser.add_argument('minimum')
    parser.add_argument('contents', type=Path)
    args = parser.parse_args()
    build(args.work, args.arch, args.minimum, args.contents)
