#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Sign verified CI payloads using a protected Actions secret, never log the key."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from release_targets import RELEASE_FLAVORS

ROOT = Path(__file__).resolve().parent.parent

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flavor', required=True, choices=RELEASE_FLAVORS)
    parser.add_argument('--tag', required=True)
    args = parser.parse_args()
    secret = os.environ.get('OSHELL_UPDATE_SIGNING_KEY', '').strip()
    if not secret:
        raise SystemExit('Missing Actions secret OSHELL_UPDATE_SIGNING_KEY. Restore the existing signing key; do not generate a replacement. Release stopped before publication.')
    repository = os.environ['GITHUB_REPOSITORY']
    # The child only receives a private file path, not the key in argv/environment.
    environment = dict(os.environ); environment.pop('OSHELL_UPDATE_SIGNING_KEY', None)
    with tempfile.TemporaryDirectory(prefix='oshell-update-signing-') as temporary:
        key = Path(temporary)/'signing.key'
        fd = os.open(key, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as stream: stream.write(secret)
        subprocess.run([sys.executable, str(ROOT/'scripts/publish-updates.py'), '--repository', repository,
                        '--tag', args.tag, '--flavor', args.flavor, '--private-key', str(key),
                        '--output', str(ROOT/'work/ci-updates')], env=environment, check=True)

if __name__ == '__main__': main()
