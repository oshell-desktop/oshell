# SPDX-License-Identifier: GPL-3.0-only
"""Compilation recipes only; packaging, version and signing changes do not invalidate them."""
import json
import os
import shutil
import subprocess
from compilation_cache import CompilationCache, swift_source_inputs, swift_configuration_inputs
from incremental_cache import IncrementalCache, affected_products

PROGRAMS = {'OShell':'MacOS/OShell', 'OShell-ZOC':'MacOS/OShell-ZOC',
    'OShell-FileZilla':'Helpers/OShell-FileZilla.app/Contents/MacOS/OShell-FileZilla',
    'OShellAskpass':'Helpers/OShellAskpass', 'OShellProxy':'Helpers/OShellProxy'}

def build_swift(root, logs, run, flavor, arch, minimum, tests=False):
    base = root / f'work/build-{flavor}'
    if tests: base = root / f'work/build-test-{flavor}-{arch}'
    variant = dict(flavor=flavor, arch=arch, minimum=minimum, tests=tests)
    sources = swift_source_inputs(root, tests=tests)
    configuration = swift_configuration_inputs()
    cache = CompilationCache(root, f'swift-{flavor}-{arch}-{minimum}', sources, variant)
    restored = base/'cached-products'
    if restored.exists(): shutil.rmtree(restored)
    products = [*PROGRAMS, 'OShellCoreChecks']
    if cache.restore(restored, products): return restored
    env = dict(os.environ, OSHELL_TEST_HARNESS='1' if tests else '0')
    args = ['swift','build','--package-path',root,'--scratch-path',base/'swift','--cache-path',base/'cache',
        '--config-path',base/'config','--security-path',base/'security','--disable-sandbox','-c','release',
        '--triple',f'{arch}-apple-macosx{minimum}', '-Xlinker','-rpath','-Xlinker','@executable_path/../Frameworks',
        '-Xlinker','-rpath','-Xlinker','@executable_path/../../../../Frameworks']
    args += ['-Xswiftc','-file-prefix-map','-Xswiftc',f'{root}=/OShell','-Xswiftc','-debug-prefix-map','-Xswiftc',f'{root}=/OShell','-Xswiftc','-file-compilation-dir','-Xswiftc','/OShell','-Xcc',f'-ffile-prefix-map={root}=/OShell']
    print('Building',flavor,arch,flush=True)
    incremental = IncrementalCache(root, f'{flavor}-{arch}-{minimum}',
        configuration, sources, variant)
    with incremental.workspace(base):
        selected = None
        if incremental.restored:
            describe = ['swift', 'package', '--package-path', root, '--scratch-path', base/'swift',
                        '--cache-path', base/'cache', '--config-path', base/'config',
                        '--security-path', base/'security', '--disable-sandbox', 'describe', '--type', 'json']
            try:
                graph = json.loads(subprocess.check_output(list(map(str, describe)), env=env, text=True))
                selected = affected_products(root, incremental.changed_inputs, graph, set(products))
            except (ValueError, OSError, subprocess.CalledProcessError):
                # Rebuilding the full graph is safe when product selection is unavailable.
                pass
        log = f'package-{flavor}-{arch}-build.log'
        if selected is None:
            run(args,env=env,log=log)
        else:
            print('SwiftPM affected products:', ', '.join(selected) or 'none', flush=True)
            with (logs/log).open('wb') as stream:
                if not selected:
                    stream.write(b'No compiled inputs changed; restored products are current.\n')
                for product in selected:
                    subprocess.run(list(map(str, [*args, '--product', product])), cwd=root, env=env,
                                   stdout=stream, stderr=subprocess.STDOUT, check=True)
    binaries = base/'swift'/f'{arch}-apple-macosx'/'release'
    cache.store(binaries, products + [p.name for p in binaries.glob('*.bundle')])
    return binaries

