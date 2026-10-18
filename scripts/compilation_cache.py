#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Runner-local, checksummed compilation products; never cache signed app bundles."""
import functools
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import stat
import subprocess
import tempfile

SCHEMA = 1


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


@functools.lru_cache(maxsize=1)
def toolchain_identity():
    commands = [['swift', '--version'], ['clang', '--version'],
                ['xcrun', '--find', 'swiftc'], ['xcrun', '--sdk', 'macosx', '--show-sdk-path'],
                ['xcrun', '--sdk', 'macosx', '--show-sdk-version']]
    return dict(commands=[subprocess.check_output(c, text=True).strip() for c in commands],
                system=platform.mac_ver()[0], host=platform.machine(),
                environment={k: os.environ.get(k, '') for k in [
                    'PATH', 'DEVELOPER_DIR', 'SDKROOT', 'TOOLCHAINS', 'SWIFT_EXEC',
                    'CPATH', 'LIBRARY_PATH', 'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH',
                    'MACOSX_DEPLOYMENT_TARGET']})


def source_key(root, inputs, variant, toolchain):
    # Checkout location matters to embedded resource and build paths. Checkout mtimes
    # and Git commit IDs do not: version/docs-only changes can reuse compiled code.
    items = []
    for name in sorted(inputs):
        source = root/name
        paths = [source, *sorted(source.rglob('*'))] if source.is_dir() else [source]
        for path in paths:
            relative = path.relative_to(root).as_posix()
            if path.is_symlink():
                if not path.resolve().is_relative_to(root.resolve()):
                    raise ValueError('Compilation input symlink points outside the checkout')
                items.append((relative, 'link', os.readlink(path)))
            elif path.is_file():
                items.append((relative, digest(path)))
            elif not path.exists():
                items.append((relative, 'absent'))
    value = dict(schema=SCHEMA, root=str(root.resolve()), variant=variant, inputs=items, toolchain=toolchain)
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def inventory(folder):
    result = {}
    for path in sorted(folder.rglob('*')):
        if path.is_symlink():
            raise ValueError('Compilation cache payload must not contain symlinks')
        if path.is_file():
            result[path.relative_to(folder).as_posix()] = dict(sha256=digest(path), mode=stat.S_IMODE(path.stat().st_mode))
    return result


class CompilationCache:
    def __init__(self, root, namespace, inputs, variant):
        configured = os.environ.get('OSHELL_COMPILATION_CACHE_DIR', '').strip()
        self.entry = None
        self.namespace = namespace
        if not configured:
            return
        try:
            cache = Path(configured)
            if not cache.is_absolute() or cache.resolve().is_relative_to(root.resolve()):
                raise ValueError('Compilation cache must be outside the checkout')
            if not re.fullmatch(r'[a-zA-Z0-9_.-]+', namespace):
                raise ValueError('Invalid compilation cache namespace')
            self.key = source_key(root, inputs, variant, toolchain_identity())
            self.parent = cache/f'v{SCHEMA}'/namespace
            self.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            self.entry = self.parent/self.key
        except (ValueError, OSError, subprocess.CalledProcessError) as error:
            self.report('DISABLED', type(error).__name__)

    def report(self, status, reason=''):
        message = f'Compilation cache {self.namespace}: {status}' + (f' ({reason})' if reason else '')
        print(message, flush=True)
        summary = os.environ.get('GITHUB_STEP_SUMMARY')
        if summary:
            with Path(summary).open('a') as stream:
                stream.write(message+'\n\n')

    def restore(self, destination, required):
        if self.entry is None:
            return False
        if destination.exists() or destination.is_symlink():
            self.report('MISS', 'restore destination already exists')
            return False
        copying = False
        try:
            if not self.entry.exists():
                self.report('MISS')
                return False
            if self.entry.is_symlink() or (self.entry/'payload').is_symlink() or (self.entry/'manifest.json').is_symlink():
                raise ValueError('Symlinked cache entry')
            manifest = json.loads((self.entry/'manifest.json').read_text())
            if not isinstance(manifest, dict) or manifest.get('schema') != SCHEMA or manifest.get('key') != self.key:
                raise ValueError('Incompatible cache manifest')
            actual = inventory(self.entry/'payload')
            if not actual or actual != manifest.get('files') or any(name not in actual for name in required):
                raise ValueError('Cache payload changed or incomplete')
            # Do not trust paths from the manifest: inventory comes from the real
            # tree and copytree refuses symlinks above. Restore only to fresh space.
            copying = True
            shutil.copytree(self.entry/'payload', destination)
            os.utime(self.entry, None)
            self.report('HIT')
            return True
        except (ValueError, OSError) as error:
            if copying and destination.exists() and not destination.is_symlink():
                # Caller provides a dedicated disposable restore directory.
                shutil.rmtree(destination)
            self.report('MISS', type(error).__name__)
            return False

    def store(self, source, outputs):
        if self.entry is None:
            return
        try:
            with tempfile.TemporaryDirectory(prefix='.staging-', dir=self.parent) as temporary:
                staged = Path(temporary)
                payload = staged/'payload'
                payload.mkdir()
                for name in outputs:
                    relative = PurePosixPath(name)
                    if relative.is_absolute() or '..' in relative.parts:
                        raise ValueError('Invalid cache output')
                    item, target = source/name, payload/name
                    if item.is_symlink():
                        raise ValueError('Symlinked cache output')
                    target.parent.mkdir(parents=True, exist_ok=True)
                    if item.is_dir():
                        shutil.copytree(item, target, symlinks=True)
                    else:
                        shutil.copy2(item, target)
                files = inventory(payload)
                if not files:
                    raise ValueError('Empty cache output')
                (staged/'manifest.json').write_text(json.dumps(dict(schema=SCHEMA, key=self.key, files=files), sort_keys=True))
                if self.entry.is_symlink():
                    raise ValueError('Symlinked cache entry')
                if self.entry.exists():
                    shutil.rmtree(self.entry)
                # Keep TemporaryDirectory's own path in place for its cleanup.
                ready = staged/'ready'
                ready.mkdir()
                payload.rename(ready/'payload')
                (staged/'manifest.json').rename(ready/'manifest.json')
                ready.rename(self.entry)
            # Bound disk usage to two generations per architecture/target namespace.
            generations = sorted((p for p in self.parent.iterdir() if re.fullmatch(r'[a-f0-9]{64}', p.name) and p.is_dir() and not p.is_symlink()),
                                 key=lambda p: p.stat().st_mtime, reverse=True)
            for old in generations[2:]:
                shutil.rmtree(old)
            self.report('SAVED')
        except (ValueError, OSError) as error:
            self.report('SAVE SKIPPED', type(error).__name__)
