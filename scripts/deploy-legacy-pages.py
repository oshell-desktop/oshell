#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Deploy only public compatibility metadata to the dedicated old Pages branch."""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

REPOSITORY = 'arnolixi/arnolixi.github.io'
BRANCH = 'master'


def normalized_private_key(secret):
    # Secret input may trim the final newline. OpenSSH requires it when
    # loading a multi-line private key, otherwise libcrypto rejects the file.
    return secret.replace(b'\r\n', b'\n').strip() + b'\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--site', type=Path, required=True)
    parser.add_argument('--key-file', type=Path)
    args = parser.parse_args()
    source = args.site.resolve()
    document = json.loads((source/'updates/macos15.json').read_text())
    if document.get('repository') != 'arnolixi/oshell' or document.get('format') != 'OShell.static-updates.v1':
        raise ValueError('Not a legacy OShell update site')
    latest = json.loads(subprocess.check_output(['gh','api','repos/oshell-desktop/oshell/releases/latest'], text=True))
    if latest['tag_name'] != 'v'+document['version']: raise ValueError('Refusing to deploy a stale update site')
    if args.key_file:
        if args.key_file.is_symlink() or args.key_file.stat().st_mode & 0o077: raise ValueError('Deploy key must be private (0600)')
        secret = args.key_file.read_bytes()
    else: secret = os.environ.pop('OSHELL_LEGACY_PAGES_DEPLOY_KEY', '').encode()
    if not secret: raise ValueError('Missing dedicated legacy Pages deploy key')
    with tempfile.TemporaryDirectory(prefix='oshell-legacy-pages-') as folder:
        root = Path(folder); checkout = root/'site'; checkout.mkdir()
        key = root/'deploy.key'; key.touch(mode=0o600); key.write_bytes(normalized_private_key(secret))
        subprocess.run(['ssh-keygen','-y','-P','','-f',str(key)],check=True,stdout=subprocess.DEVNULL)
        # Fetch GitHub's published host keys over authenticated HTTPS; do not
        # accept arbitrary SSH keys or disable host identity verification.
        meta = json.loads(subprocess.check_output(['gh','api','meta'],text=True))
        known = root/'known_hosts'
        known.write_text(''.join('[ssh.github.com]:443 '+value+'\n' for value in meta['ssh_keys']))
        command = ['ssh','-i',str(key),'-p','443','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o','UserKnownHostsFile='+str(known)]
        env = dict(os.environ, GIT_SSH_COMMAND=shlex.join(command), GIT_TERMINAL_PROMPT='0')
        def git(*args, capture=False):
            return subprocess.run(['git',*args],cwd=checkout,env=env,check=True,text=True,stdout=subprocess.PIPE if capture else None).stdout
        git('init','-q')
        git('remote','add','origin','ssh://git@ssh.github.com:443/'+REPOSITORY+'.git')
        existing = git('ls-remote','origin','refs/heads/'+BRANCH,capture=True).strip()
        if existing:
            git('fetch','--depth=1','origin',BRANCH)
            git('checkout','-b',BRANCH,'FETCH_HEAD')
        else: git('checkout','--orphan',BRANCH)
        old = checkout/'oshell/updates/macos15.json'
        if old.exists() and int(json.loads(old.read_text())['build']) > int(document['build']):
            raise ValueError('Refusing to replace a newer compatibility site')
        for relative in ['index.html','updates/latest.json','updates/macos15.json']:
            target = checkout/'oshell'/relative; target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source/relative,target)
        (checkout/'.nojekyll').write_text('')
        git('add','--','.nojekyll','oshell/index.html','oshell/updates/latest.json','oshell/updates/macos15.json')
        if not git('diff','--cached','--name-only',capture=True).strip():
            print('Legacy Pages already current; no push/build needed.'); return
        git('-c','user.name=OShell Updates','-c','user.email=updates@users.noreply.github.com',
            'commit','-m','Update OShell compatibility feed to '+document['version'])
        git('push','origin','HEAD:refs/heads/'+BRANCH)
        print('Published compatibility metadata only; no source, credentials or installers deployed to Pages.')


if __name__ == '__main__': main()
