# SPDX-License-Identifier: GPL-3.0-only
"""Standalone lrzsz build recipe, independent of Swift and installer assembly."""
import os
import shutil
from compilation_cache import CompilationCache

def build_lrzsz(root, work, run, arch, minimum):
    base = work/f'lrzsz-{arch}-{minimum}'
    cache = CompilationCache(root, f'lrzsz-{arch}-{minimum}',
        ['Vendor/lrzsz-0.12.20.tar.gz', 'scripts/release_helpers.py', 'scripts/compilation_cache.py'],
        dict(arch=arch, minimum=minimum))
    restored = work/f'cached-lrzsz-{arch}-{minimum}'
    if restored.exists(): shutil.rmtree(restored)
    products = ['src/lrz', 'src/lsz', 'COPYING']
    if cache.restore(restored, products): return restored/'src'
    marker = base/'.built-public-paths'
    if cache.entry is not None or not marker.exists():
        base.mkdir(parents=True,exist_ok=True)
        run(['tar','-xzf',root/'Vendor/lrzsz-0.12.20.tar.gz','--strip-components=1','-C',base])
        env=dict(os.environ,CC='clang',CFLAGS=f'-arch {arch} -Os -mmacosx-version-min={minimum} -std=gnu89 -Wno-error=implicit-function-declaration -Wno-error=incompatible-function-pointer-types -ffile-prefix-map={root}=/OShell -fdebug-prefix-map={root}=/OShell',LDFLAGS=f'-arch {arch} -mmacosx-version-min={minimum}')
        host='arm' if arch=='arm64' else 'x86_64'
        run(['./configure','--disable-nls','--disable-timesync',f'--host={host}-apple-darwin','--prefix=/usr'],cwd=base,env=env,log=f'package-lrzsz-{arch}-{minimum}-configure.log')
        run(['make','clean'],cwd=base,env=env,log=f'package-lrzsz-{arch}-{minimum}-clean.log')
        run(['make','-j4'],cwd=base,env=env,log=f'package-lrzsz-{arch}-{minimum}-build.log')
        marker.write_text('OShell reproducible helper build\n')
    cache.store(base, products)
    return base/'src'

