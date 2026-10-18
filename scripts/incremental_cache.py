#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Checksummed SwiftPM state with content-aware checkout timestamp restoration."""
import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile
import time
from compilation_cache import CompilationCache, digest

STATE_SCHEMA = 1


def source_records(root, inputs):
    records = {}
    for name in inputs:
        source = root/name
        paths = [source, *sorted(source.rglob('*'))] if source.is_dir() else [source]
        for path in paths:
            if path.is_symlink():
                if not path.resolve().is_relative_to(root.resolve()):
                    raise ValueError('Source symlink points outside the checkout')
                continue
            if not path.is_file():
                continue
            info = path.stat()
            records[path.relative_to(root).as_posix()] = dict(
                sha256=digest(path), mode=stat.S_IMODE(info.st_mode), mtime_ns=info.st_mtime_ns)
    return records


def build_inventory(root):
    """Permit SwiftPM's relative release symlink, but never external links."""
    result = {}
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            target = os.readlink(path)
            if Path(target).is_absolute() or not path.resolve().is_relative_to(root.resolve()):
                raise ValueError('External symlink in SwiftPM state')
            result[relative] = dict(link=target)
        elif path.is_file():
            info = path.stat()
            result[relative] = dict(sha256=digest(path), mode=stat.S_IMODE(info.st_mode), mtime_ns=info.st_mtime_ns)
    return result


def validate_inventory(expected, actual):
    if not isinstance(expected, dict) or expected.keys() != actual.keys():
        raise ValueError('SwiftPM inventory changed')
    for name, current in actual.items():
        previous = expected[name]
        if not isinstance(previous, dict) or previous.keys() != current.keys():
            raise ValueError('Invalid SwiftPM file record')
        if 'link' in current:
            if previous != current:
                raise ValueError('SwiftPM symlink changed')
        else:
            timestamp = previous['mtime_ns']
            if (previous['sha256'] != current['sha256'] or previous['mode'] != current['mode']
                    or not isinstance(timestamp, int) or timestamp < 0 or timestamp >= 2**63):
                raise ValueError('SwiftPM file changed')


class IncrementalCache(CompilationCache):
    def __init__(self, root, namespace, configuration_inputs, source_inputs, variant):
        super().__init__(root, 'swiftpm-'+namespace, configuration_inputs,
                         dict(variant=variant, stateSchema=STATE_SCHEMA))
        self.root = root
        self.source_inputs = source_inputs

    def clear_build_state(self, base):
        # Only the caller's disposable build directories, never source/config/keys.
        if not base.resolve().is_relative_to((self.root/'work').resolve()) or base.is_symlink():
            raise ValueError('SwiftPM workspace must be under checkout/work')
        for name in ['swift', 'cache']:
            path = base/name
            if path.is_symlink():
                path.unlink()
            elif path.exists():
                shutil.rmtree(path)

    def restore_state(self, base):
        try:
            if not self.entry.exists():
                self.clear_build_state(base)
                self.report('COLD')
                return False
            if self.entry.is_symlink() or (self.entry/'payload').is_symlink() or (self.entry/'state.json').is_symlink():
                raise ValueError('Symlinked SwiftPM snapshot')
            state = json.loads((self.entry/'state.json').read_text())
            if (not isinstance(state, dict) or state.get('schema') != STATE_SCHEMA
                    or state.get('key') != self.key or not isinstance(state.get('sources'), dict)):
                raise ValueError('Incompatible SwiftPM state')
            files = build_inventory(self.entry/'payload')
            if not files or 'swift/build.db' not in files:
                raise ValueError('SwiftPM state changed or incomplete')
            validate_inventory(state.get('files'), files)
            self.clear_build_state(base)
            base.mkdir(parents=True, exist_ok=True)
            for name in ['swift', 'cache']:
                source = self.entry/'payload'/name
                if source.exists():
                    shutil.copytree(source, base/name, symlinks=True)
            # Cache archive transports can round mtimes. Validate bytes and modes
            # first, then restore the original nanosecond timestamps llbuild saw.
            for relative, info in files.items():
                if 'mtime_ns' in info:
                    path = base/relative
                    os.utime(path, ns=(path.stat().st_atime_ns, state['files'][relative]['mtime_ns']))
            current = source_records(self.root, self.source_inputs)
            unchanged = changed = 0
            # Iterate current trusted source paths, not paths supplied by cache JSON.
            for relative, info in current.items():
                previous = state['sources'].get(relative)
                path = self.root/relative
                if (isinstance(previous, dict) and previous.get('sha256') == info['sha256']
                        and previous.get('mode') == info['mode']
                        and isinstance(previous.get('mtime_ns'), int)):
                    timestamp = previous['mtime_ns']
                    if timestamp < 0 or timestamp >= 2**63:
                        raise ValueError('Invalid cached source timestamp')
                    os.utime(path, ns=(path.stat().st_atime_ns, timestamp))
                    unchanged += 1
                else:
                    # Content changes must remain dirty even if a checkout/tool
                    # happened to reuse the old timestamp and file size.
                    old = previous.get('mtime_ns', 0) if isinstance(previous, dict) else 0
                    if not isinstance(old, int) or old < 0 or old >= 2**63 - 1_000_000_000:
                        raise ValueError('Invalid previous source timestamp')
                    timestamp = max(time.time_ns(), old + 1_000_000_000)
                    os.utime(path, ns=(path.stat().st_atime_ns, timestamp))
                    changed += 1
            removed = len(set(state['sources']) - set(current))
            self.report('RESTORED', f'{unchanged} unchanged, {changed} changed/new, {removed} removed')
            return True
        except (ValueError, OSError, OverflowError) as error:
            self.clear_build_state(base)
            self.report('COLD', type(error).__name__)
            return False

    def save_state(self, base):
        try:
            with tempfile.TemporaryDirectory(prefix='.state-', dir=self.parent) as temporary:
                staged = Path(temporary)
                payload = staged/'payload'; payload.mkdir()
                for name in ['swift', 'cache']:
                    if (base/name).exists():
                        shutil.copytree(base/name, payload/name, symlinks=True)
                files = build_inventory(payload)
                if 'swift/build.db' not in files:
                    raise ValueError('SwiftPM build database missing')
                state = dict(schema=STATE_SCHEMA, key=self.key, files=files,
                             sources=source_records(self.root, self.source_inputs))
                ready = staged/'ready'; ready.mkdir()
                payload.rename(ready/'payload')
                (ready/'state.json').write_text(json.dumps(state, sort_keys=True))
                if self.entry.is_symlink():
                    raise ValueError('Symlinked SwiftPM cache entry')
                if self.entry.exists():
                    shutil.rmtree(self.entry)
                ready.rename(self.entry)
            # Keep one successful toolchain/configuration snapshot per target.
            # Exact compiled-product cache keeps its own two-generation policy.
            for old in self.parent.iterdir():
                if old != self.entry and re.fullmatch(r'[a-f0-9]{64}', old.name) and old.is_dir() and not old.is_symlink():
                    shutil.rmtree(old)
            self.report('SAVED')
        except (ValueError, OSError) as error:
            self.report('SAVE SKIPPED', type(error).__name__)

    @contextlib.contextmanager
    def workspace(self, base):
        if self.entry is None:
            yield
            return
        # Serialize restore/build/snapshot for this target. The cached snapshot
        # stays immutable until a successful build replaces it; failures keep it.
        with (self.parent/'.state.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.restore_state(base)
            yield
            self.save_state(base)
