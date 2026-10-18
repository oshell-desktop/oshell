#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Synthetic state tests plus an opt-in real SwiftPM dependency rebuild test."""
import os
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import compilation_cache
from incremental_cache import IncrementalCache, affected_products

REAL_SWIFT = '--swift-integration' in sys.argv
if REAL_SWIFT:
    sys.argv.remove('--swift-integration')


class StateTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory(prefix='oshell-incremental-test-')
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)
        self.root = self.folder/'source'; self.root.mkdir()
        (self.root/'Package.swift').write_text('synthetic manifest')
        (self.root/'Sources').mkdir()
        self.source = self.root/'Sources/A.swift'; self.source.write_text('old')
        self.base = self.root/'work/build'
        for context in [patch.dict(os.environ, {'OSHELL_COMPILATION_CACHE_DIR': str(self.folder/'cache'), 'GITHUB_STEP_SUMMARY': ''}),
                        patch.object(compilation_cache, 'toolchain_identity', return_value={'swift': 'fixture'})]:
            context.start(); self.addCleanup(context.stop)

    def cache(self, **variant):
        return IncrementalCache(self.root, 'fixture', ['Package.swift'], ['Package.swift', 'Sources'], variant)

    def fake_build(self):
        (self.base/'swift/target/release').mkdir(parents=True, exist_ok=True)
        (self.base/'swift/build.db').write_text('synthetic build database')
        (self.base/'swift/target/release/product').write_text('synthetic object')
        (self.base/'swift/release').symlink_to('target/release')
        (self.base/'config').mkdir(exist_ok=True)
        (self.base/'config/token').write_text('synthetic credential: do not cache')

    def seed(self):
        cache = self.cache()
        with cache.workspace(self.base): self.fake_build()
        return cache

    def test_unchanged_sources_restore_mtime_after_fresh_checkout(self):
        cache = self.seed(); old = self.source.stat().st_mtime_ns
        self.source.unlink(); self.source.write_text('old'); os.utime(self.source, ns=(1, 1))
        with cache.workspace(self.base):
            self.assertEqual(self.source.stat().st_mtime_ns, old)
            self.assertTrue((self.base/'swift/release/product').exists())
        self.assertFalse((cache.entry/'payload/config').exists())

    def test_changed_same_size_source_with_old_mtime_stays_dirty(self):
        cache = self.seed(); old = self.source.stat().st_mtime_ns
        self.source.write_text('new'); os.utime(self.source, ns=(old, old))
        with cache.workspace(self.base):
            self.assertNotEqual(self.source.stat().st_mtime_ns, old)
            self.assertEqual(self.source.read_text(), 'new')

    def test_added_and_removed_sources_are_not_replaced(self):
        cache = self.seed(); self.source.unlink()
        added = self.root/'Sources/B.swift'; added.write_text('added')
        with cache.workspace(self.base):
            self.assertFalse(self.source.exists())
            self.assertEqual(added.read_text(), 'added')

    def test_source_changes_reuse_state_but_manifest_changes_do_not(self):
        first = self.cache().key
        self.source.write_text('changed')
        self.assertEqual(first, self.cache().key)
        (self.root/'Package.swift').write_text('new manifest')
        self.assertNotEqual(first, self.cache().key)

    def test_targets_and_toolchains_are_isolated(self):
        self.assertNotEqual(self.cache(arch='arm64').key, self.cache(arch='x86_64').key)
        first = self.cache().key
        with patch.object(compilation_cache, 'toolchain_identity', return_value={'swift': 'new'}):
            self.assertNotEqual(first, self.cache().key)

    def test_corrupt_snapshot_forces_clean_build_state(self):
        cache = self.seed()
        (cache.entry/'payload/swift/build.db').write_text('broken')
        with cache.workspace(self.base):
            self.assertFalse((self.base/'swift').exists())
            self.assertEqual((self.base/'config/token').read_text(), 'synthetic credential: do not cache')
            self.fake_build()

    def test_failed_build_keeps_previous_successful_snapshot(self):
        cache = self.seed(); before = (cache.entry/'state.json').read_bytes()
        with self.assertRaisesRegex(RuntimeError, 'synthetic failure'):
            with cache.workspace(self.base):
                (self.base/'swift/build.db').write_text('partial')
                raise RuntimeError('synthetic failure')
        self.assertEqual((cache.entry/'state.json').read_bytes(), before)
        with cache.workspace(self.base):
            self.assertEqual((self.base/'swift/build.db').read_text(), 'synthetic build database')

    def test_archive_mtime_rounding_does_not_force_recompilation(self):
        cache = self.seed()
        original = (self.base/'swift/build.db').stat().st_mtime_ns
        archived = cache.entry/'payload/swift/build.db'
        rounded = original // 1_000_000_000 * 1_000_000_000
        os.utime(archived, ns=(rounded, rounded))
        with cache.workspace(self.base):
            self.assertEqual((self.base/'swift/build.db').stat().st_mtime_ns, original)

    def test_external_snapshot_symlink_forces_cold_build(self):
        cache = self.seed()
        (cache.entry/'payload/swift/external').symlink_to(self.folder)
        with cache.workspace(self.base):
            self.assertFalse((self.base/'swift').exists())
            self.fake_build()


class ProductSelectionTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory(prefix='oshell-product-selection-')
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        self.graph = {'targets': [
            {'name': 'Core', 'path': 'Sources/Core', 'sources': ['Core.swift'], 'product_memberships': ['App', 'Helper']},
            {'name': 'App', 'path': 'Sources/App', 'sources': ['main.swift'], 'product_memberships': ['App']},
            {'name': 'Helper', 'path': 'Sources/Helper', 'sources': ['main.swift'], 'product_memberships': ['Helper']}]}
        for target in self.graph['targets']:
            path = self.root/target['path']; path.mkdir(parents=True)
            for source in target['sources']: (path/source).write_text('fixture')

    def select(self, *paths):
        return affected_products(self.root, set(paths), self.graph, {'App', 'Helper'})

    def test_leaf_change_does_not_select_unrelated_app(self):
        self.assertEqual(self.select('Sources/Helper/main.swift'), ['Helper'])

    def test_library_change_selects_all_consumers(self):
        self.assertEqual(self.select('Sources/Core/Core.swift'), ['App', 'Helper'])

    def test_removed_source_still_selects_its_product(self):
        (self.root/'Sources/Helper/main.swift').unlink()
        self.graph['targets'][2]['sources'] = []
        self.assertEqual(self.select('Sources/Helper/main.swift'), ['Helper'])

    def test_new_source_is_discovered_in_current_graph(self):
        (self.root/'Sources/Helper/New.swift').write_text('new')
        self.graph['targets'][2]['sources'].append('New.swift')
        self.assertEqual(self.select('Sources/Helper/New.swift'), ['Helper'])

    def test_unrecognized_inputs_fall_back_to_full_graph(self):
        self.assertIsNone(self.select('Vendor/Dependency/Code.swift'))
        (self.root/'Sources/Helper/bridge.h').write_text('header')
        self.assertIsNone(self.select('Sources/Helper/bridge.h'))

    def test_invalid_memberships_fall_back_to_full_graph(self):
        self.graph['targets'][2]['product_memberships'] = [{'invalid': 'record'}]
        self.assertIsNone(self.select('Sources/Helper/main.swift'))

    def test_no_changes_require_no_products(self):
        self.assertEqual(self.select(), [])


@unittest.skipUnless(REAL_SWIFT, 'use --swift-integration on macOS to run real compiler checks')
class RealSwiftTests(unittest.TestCase):
    def test_fresh_checkout_rebuilds_only_affected_targets_and_updates_binary(self):
        with tempfile.TemporaryDirectory(prefix='oshell-swift-incremental-') as folder:
            root = Path(folder)/'source'; root.mkdir()
            (root/'Sources/Base').mkdir(parents=True); (root/'Sources/Probe').mkdir()
            (root/'Sources/BinaryConsumer').mkdir()
            vendor = Path(__file__).resolve().parent.parent/'Vendor/Sparkle/Sparkle.xcframework'
            shutil.copytree(vendor, root/'Artifacts/Sparkle.xcframework', symlinks=True)
            (root/'Sources/BinaryConsumer/main.swift').write_text('import Sparkle\nprint("unrelated binary-framework consumer")\n')
            (root/'Package.swift').write_text('// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "Probe", platforms: [.macOS(.v11)], targets: [.binaryTarget(name:"Sparkle", path:"Artifacts/Sparkle.xcframework"), .target(name:"Base", resources:[.copy("fixture.txt")]), .executableTarget(name:"Probe", dependencies:["Base"]), .executableTarget(name:"BinaryConsumer", dependencies:["Sparkle"])])\n')
            (root/'Sources/Base/fixture.txt').write_text('unchanged resource')
            library = root/'Sources/Base/Base.swift'; library.write_text('public func value() -> String { "base" }\n')
            client = root/'Sources/Probe/main.swift'; client.write_text('import Base\nprint(value())\nprint("one")\n')
            base = root/'work/build'
            env = dict(os.environ, OSHELL_COMPILATION_CACHE_DIR=str(Path(folder)/'cache'), GITHUB_STEP_SUMMARY='')
            with patch.dict(os.environ, env):
                def build():
                    # Recreate all source files with new inodes and mtimes, as a
                    # clean checkout may do. Cache must identify content equality.
                    for path in [root/'Package.swift', *root.glob('Sources/**/*.swift')]:
                        content = path.read_bytes(); path.unlink(); path.write_bytes(content)
                    for path in (root/'Artifacts').rglob('*'):
                        if path.is_dir() or path.is_symlink():
                            os.utime(path, follow_symlinks=False)
                    cache = IncrementalCache(root, 'real-swift', ['Package.swift', 'Artifacts'], ['Package.swift', 'Sources', 'Artifacts'], {'mode':'release'})
                    if cache.entry.exists():
                        # Exercise a transport that rounds output file timestamps.
                        for path in (cache.entry/'payload').rglob('*'):
                            if path.is_file() and not path.is_symlink():
                                rounded = path.stat().st_mtime_ns // 1_000_000_000 * 1_000_000_000
                                os.utime(path, ns=(rounded, rounded))
                    with cache.workspace(base):
                        options = ['--package-path',str(root),'--scratch-path',str(base/'swift'),
                                '--cache-path',str(base/'cache'),'--config-path',str(base/'config'),
                                '--security-path',str(base/'security'),'--disable-sandbox']
                        args = ['swift', 'build', *options, '-c', 'release']
                        if cache.restored:
                            graph = json.loads(subprocess.check_output(['swift', 'package', *options, 'describe', '--type', 'json'], env=env, text=True))
                            selected = affected_products(root, cache.changed_inputs, graph, {'Probe', 'BinaryConsumer'})
                            self.assertEqual(selected, ['Probe'])
                            args += ['--product', 'Probe']
                        result = subprocess.run(args, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=True)
                    print(result.stdout, flush=True)
                    executable = next((base/'swift').glob('*-apple-macosx/release/Probe'))
                    return result.stdout, subprocess.check_output([str(executable)], text=True)

                first, output = build(); self.assertEqual(output, 'base\none\n')
                shutil.rmtree(root/'work')
                client.write_text('import Base\nprint(value())\nprint("two")\n')
                second, output = build()
                self.assertIn('Compiling Probe', second)
                self.assertNotIn('Compiling Base', second)
                self.assertNotIn('Compiling BinaryConsumer', second)
                self.assertEqual(output, 'base\ntwo\n')
                added = root/'Sources/Base/Added.swift'; added.write_text('func extra() -> String { "added" }\n')
                library.write_text('public func value() -> String { extra() }\n')
                third, output = build(); self.assertIn('Compiling Base', third)
                self.assertNotIn('Compiling BinaryConsumer', third)
                self.assertEqual(output, 'added\ntwo\n')
                added.unlink(); library.write_text('public func value() -> String { "removed" }\n')
                fourth, output = build(); self.assertIn('Compiling Base', fourth)
                self.assertNotIn('Compiling BinaryConsumer', fourth)
                self.assertEqual(output, 'removed\ntwo\n')


if __name__ == '__main__':
    unittest.main()
