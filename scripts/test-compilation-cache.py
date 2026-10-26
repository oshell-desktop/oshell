#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Synthetic cache invalidation and integrity tests; no user data or toolchain needed."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import compilation_cache as CACHE


class CompilationCacheTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory(prefix='oshell-cache-test-')
        self.addCleanup(folder.cleanup)
        self.base = Path(folder.name)
        self.root = self.base/'checkout'
        self.root.mkdir()
        (self.root/'Sources').mkdir()
        (self.root/'Sources/app.swift').write_text('print("fixture")')
        self.products = self.base/'products'
        self.products.mkdir()
        (self.products/'app').write_bytes(b'compiled fixture')
        (self.products/'app').chmod(0o755)
        (self.products/'Resources.bundle').mkdir()
        (self.products/'Resources.bundle/data').write_text('resource')
        (self.products/'private.key').write_text('must never be cached')
        for context in [patch.dict(os.environ, {'OSHELL_COMPILATION_CACHE_DIR': str(self.base/'cache')}, clear=True),
                        patch.object(CACHE, 'toolchain_identity', return_value={'swift': 'fixture-v1'})]:
            context.start()
            self.addCleanup(context.stop)

    def cache(self, **variant):
        return CACHE.CompilationCache(self.root, 'swift-arm64-15.0', ['Sources', 'Package.resolved'], variant)

    def store(self, cache):
        cache.store(self.products, ['app', 'Resources.bundle'])

    def test_round_trip_only_selected_products_and_executable_mode(self):
        cache = self.cache(); self.store(cache)
        output = self.base/'restored'
        self.assertTrue(cache.restore(output, ['app']))
        self.assertEqual((output/'app').read_bytes(), b'compiled fixture')
        self.assertTrue(os.access(output/'app', os.X_OK))
        self.assertEqual((output/'Resources.bundle/data').read_text(), 'resource')
        self.assertFalse((output/'private.key').exists())

    def test_checkout_timestamps_and_docs_do_not_invalidate(self):
        first = self.cache().key
        os.utime(self.root/'Sources/app.swift', (1, 1))
        (self.root/'README.md').write_text('documentation change')
        (self.root/'Info.plist').write_text('version change')
        self.assertEqual(first, self.cache().key)

    def test_source_change_or_removal_invalidates(self):
        first = self.cache().key
        (self.root/'Sources/app.swift').write_text('print("changed")')
        second = self.cache().key
        self.assertNotEqual(first, second)
        (self.root/'Sources/app.swift').unlink()
        self.assertNotEqual(second, self.cache().key)

    def test_architecture_minimum_and_test_mode_are_isolated(self):
        variants = [dict(arch='arm64', minimum='15.0', tests=False),
                    dict(arch='x86_64', minimum='15.0', tests=False),
                    dict(arch='arm64', minimum='11.0', tests=False),
                    dict(arch='arm64', minimum='15.0', tests=True)]
        self.assertEqual(len({self.cache(**v).key for v in variants}), 4)

    def production_key(self, tests=False):
        return CACHE.source_key(self.root, CACHE.swift_source_inputs(self.root, tests=tests), {}, {'swift':'fixture'})

    def write_input(self, name, value):
        path = self.root/name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text(value)

    def test_production_excludes_ui_tests_but_test_build_includes_them(self):
        self.write_input('Sources/OShell/App.swift', 'app')
        self.write_input('Sources/OShell/TestSupport/Fixture.swift', 'first')
        production, tests = self.production_key(), self.production_key(tests=True)
        self.write_input('Sources/OShell/TestSupport/Fixture.swift', 'second')
        self.assertEqual(production, self.production_key())
        self.assertNotEqual(tests, self.production_key(tests=True))
        self.write_input('Sources/OShell/Added.swift', 'new production code')
        self.assertNotEqual(production, self.production_key())
        (self.root/'Sources/OShell/Added.swift').unlink()
        self.assertEqual(production, self.production_key())

    def test_packaging_version_and_helper_recipe_do_not_invalidate_swift(self):
        first = self.production_key()
        for path in ['scripts/package-release.py', 'scripts/Info.plist', 'scripts/release_helpers.py']:
            self.write_input(path, 'changed')
        self.assertEqual(first, self.production_key())
        self.write_input('scripts/release_compilation.py', 'changed flags')
        self.assertNotEqual(first, self.production_key())

    def test_core_checks_and_relevant_dependencies_still_invalidate(self):
        first = self.production_key()
        self.write_input('Vendor/SwiftTerm/Sources/Terminal.swift', 'renderer change')
        self.assertNotEqual(first, self.production_key())
        first = self.production_key()
        self.write_input('Tests/OShellCoreTests/CoreTests.swift', 'new assertion')
        self.assertNotEqual(first, self.production_key())

    def test_excluded_test_support_does_not_hide_external_source_symlink(self):
        (self.root/'Sources/OShell').symlink_to(self.products, target_is_directory=True)
        with self.assertRaises(ValueError): self.production_key()

    def test_toolchain_change_invalidates(self):
        first = self.cache().key
        with patch.object(CACHE, 'toolchain_identity', return_value={'swift': 'fixture-v2'}):
            self.assertNotEqual(first, self.cache().key)

    def test_corrupted_product_is_miss_and_can_be_rebuilt(self):
        cache = self.cache(); self.store(cache)
        (cache.entry/'payload/app').write_bytes(b'corrupted')
        output = self.base/'restored'
        self.assertFalse(cache.restore(output, ['app']))
        self.assertFalse(output.exists())
        self.store(cache)
        self.assertTrue(cache.restore(output, ['app']))

    def test_missing_required_product_is_miss(self):
        cache = self.cache(); self.store(cache)
        self.assertFalse(cache.restore(self.base/'restored', ['OShellCoreChecks']))

    def test_unknown_schema_and_missing_payload_are_misses(self):
        cache = self.cache(); self.store(cache)
        manifest = cache.entry/'manifest.json'
        content = json.loads(manifest.read_text()); content['schema'] = 999
        manifest.write_text(json.dumps(content))
        self.assertFalse(cache.restore(self.base/'restored', ['app']))
        self.store(cache)
        (cache.entry/'payload/Resources.bundle/data').unlink()
        self.assertFalse(cache.restore(self.base/'restored', ['app']))

    def test_symlinked_product_cannot_be_cached(self):
        (self.products/'Resources.bundle/link').symlink_to(self.products/'private.key')
        cache = self.cache(); self.store(cache)
        self.assertFalse(cache.entry.exists())

    def test_existing_restore_directory_is_not_deleted(self):
        cache = self.cache(); self.store(cache)
        output = self.base/'restored'; output.mkdir()
        (output/'keep').write_text('keep')
        self.assertFalse(cache.restore(output, ['app']))
        self.assertEqual((output/'keep').read_text(), 'keep')

    def test_outside_checkout_symlink_disables_cache(self):
        (self.root/'Sources/external').symlink_to(self.products/'private.key')
        self.assertIsNone(self.cache().entry)

    def test_cache_inside_checkout_is_disabled(self):
        with patch.dict(os.environ, {'OSHELL_COMPILATION_CACHE_DIR': str(self.root/'cache')}):
            self.assertIsNone(self.cache().entry)

    def test_cache_retains_only_two_generations(self):
        for version in range(3):
            cache = self.cache(version=version); self.store(cache)
            os.utime(cache.entry, (100 + version, 100 + version))
        self.assertEqual(len(list(cache.parent.iterdir())), 2)


if __name__ == '__main__':
    unittest.main()
