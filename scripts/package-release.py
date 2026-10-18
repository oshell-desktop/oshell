#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""Build catalogued macOS apps, then produce DMG or PKG + DMG files.
Never installs an app or replaces the developer's dist/OShell.app.
"""
import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
from release_targets import TARGETS, RELEASE_FLAVORS
import installer_metadata
import code_signing
from compilation_cache import CompilationCache
from incremental_cache import IncrementalCache

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / 'work/release'
OUT = ROOT / 'dist/installers'
LOG = ROOT / 'validation'
INFO = plistlib.loads((ROOT/'scripts/Info.plist').read_bytes())
INCLUDE_TESTS = False
VERSION = INFO['CFBundleShortVersionString']
PROGRAMS = {'OShell':'MacOS/OShell', 'OShell-ZOC':'MacOS/OShell-ZOC',
    'OShell-FileZilla':'Helpers/OShell-FileZilla.app/Contents/MacOS/OShell-FileZilla',
    'OShellAskpass':'Helpers/OShellAskpass', 'OShellProxy':'Helpers/OShellProxy', 'OShellSSH':'Helpers/OShellSSH'}

def run(args, *, log=None, env=None, cwd=ROOT):
    if log:
        with (LOG/log).open('wb') as output:
            subprocess.run(list(map(str,args)),cwd=cwd,env=env,stdout=output,stderr=subprocess.STDOUT,check=True)
    else: subprocess.run(list(map(str,args)),cwd=cwd,env=env,check=True)

def output(args):
    return subprocess.check_output(list(map(str,args)),text=True).strip()

def core_check_command(binaries, native):
    if native in binaries:
        return [binaries[native]/'OShellCoreChecks']
    if native == 'arm64' and 'x86_64' in binaries:
        # Validate Intel-only targets on Apple Silicon without skipping their checks.
        return ['/usr/bin/arch', '-x86_64', binaries['x86_64']/'OShellCoreChecks']
    raise RuntimeError('Core checks require a native target or x86_64 via Rosetta on Apple Silicon')

def build_swift(flavor, arch, minimum):
    base = ROOT / ('work/build-legacy' if flavor == 'legacy' else f'work/build-compat-{arch}' if flavor == 'compat' else f'work/build-modern-{arch}')
    if INCLUDE_TESTS: base = ROOT / f'work/build-test-{flavor}-{arch}'
    inputs = ['Package.swift', 'Package.resolved', 'Sources', 'Tests/OShellCoreTests',
         'Vendor/SwiftTerm', 'Vendor/CryptoSwift', 'Vendor/Sparkle/Sparkle.xcframework',
         'scripts/package-release.py', 'scripts/compilation_cache.py', 'scripts/incremental_cache.py']
    variant = dict(flavor=flavor, arch=arch, minimum=minimum, tests=INCLUDE_TESTS)
    cache = CompilationCache(ROOT, f'swift-{flavor}-{arch}-{minimum}', inputs, variant)
    restored = base/'cached-products'
    if restored.exists(): shutil.rmtree(restored)
    products = [*PROGRAMS, 'OShellCoreChecks']
    if cache.restore(restored, products): return restored
    env = dict(os.environ, OSHELL_LEGACY='1' if flavor == 'legacy' else '0', OSHELL_MACOS_MINIMUM=minimum, OSHELL_TEST_HARNESS='1' if INCLUDE_TESTS else '0')
    args = ['swift','build','--package-path',ROOT,'--scratch-path',base/'swift','--cache-path',base/'cache',
        '--config-path',base/'config','--security-path',base/'security','--disable-sandbox','-c','release',
        '--triple',f'{arch}-apple-macosx{minimum}', '-Xlinker','-rpath','-Xlinker','@executable_path/../Frameworks',
        '-Xlinker','-rpath','-Xlinker','@executable_path/../../../../Frameworks']
    args += ['-Xswiftc','-file-prefix-map','-Xswiftc',f'{ROOT}=/OShell','-Xswiftc','-debug-prefix-map','-Xswiftc',f'{ROOT}=/OShell','-Xswiftc','-file-compilation-dir','-Xswiftc','/OShell','-Xcc',f'-ffile-prefix-map={ROOT}=/OShell']
    if flavor == 'legacy': args += ['-Xswiftc','-DOSHELL_LEGACY']
    print('Building',flavor,arch,flush=True)
    incremental = IncrementalCache(ROOT, f'{flavor}-{arch}-{minimum}',
        ['Package.swift', 'Package.resolved', 'Vendor/SwiftTerm/Package.swift',
         'Vendor/CryptoSwift/Package.swift', 'Vendor/Sparkle/Sparkle.xcframework',
         'scripts/package-release.py', 'scripts/compilation_cache.py', 'scripts/incremental_cache.py'],
        inputs, variant)
    with incremental.workspace(base):
        run(args,env=env,log=f'package-{flavor}-{arch}-build.log')
    binaries = base/'swift'/f'{arch}-apple-macosx'/'release'
    cache.store(binaries, products + [p.name for p in binaries.glob('*.bundle')])
    return binaries

def build_lrzsz(arch, minimum):
    base = WORK/f'lrzsz-{arch}-{minimum}'
    cache = CompilationCache(ROOT, f'lrzsz-{arch}-{minimum}',
        ['Vendor/lrzsz-0.12.20.tar.gz', 'scripts/package-release.py', 'scripts/compilation_cache.py'],
        dict(arch=arch, minimum=minimum))
    restored = WORK/f'cached-lrzsz-{arch}-{minimum}'
    if restored.exists(): shutil.rmtree(restored)
    products = ['src/lrz', 'src/lsz', 'COPYING']
    if cache.restore(restored, products): return restored/'src'
    marker = base/'.built-public-paths'
    if cache.entry is not None or not marker.exists():
        base.mkdir(parents=True,exist_ok=True)
        run(['tar','-xzf',ROOT/'Vendor/lrzsz-0.12.20.tar.gz','--strip-components=1','-C',base])
        env=dict(os.environ,CC='clang',CFLAGS=f'-arch {arch} -Os -mmacosx-version-min={minimum} -std=gnu89 -Wno-error=implicit-function-declaration -Wno-error=incompatible-function-pointer-types -ffile-prefix-map={ROOT}=/OShell -fdebug-prefix-map={ROOT}=/OShell',LDFLAGS=f'-arch {arch} -mmacosx-version-min={minimum}')
        host='arm' if arch=='arm64' else 'x86_64'
        run(['./configure','--disable-nls','--disable-timesync',f'--host={host}-apple-darwin','--prefix=/usr'],cwd=base,env=env,log=f'package-lrzsz-{arch}-{minimum}-configure.log')
        run(['make','clean'],cwd=base,env=env,log=f'package-lrzsz-{arch}-{minimum}-clean.log')
        run(['make','-j4'],cwd=base,env=env,log=f'package-lrzsz-{arch}-{minimum}-build.log')
        marker.write_text('OShell reproducible helper build\n')
    cache.store(base, products)
    return base/'src'

def macho(path):
    if not path.is_file() or path.is_symlink(): return False
    with path.open('rb') as f: return f.read(4) in [b'\xcf\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca']

def assemble(flavor, arches, minimum, binaries, helpers):
    app = WORK/flavor/'OShell.app'
    if app.exists(): shutil.rmtree(app)
    contents=app/'Contents'; resources=contents/'Resources'
    resources.mkdir(parents=True)
    for name, relative in PROGRAMS.items():
        target=contents/relative; target.parent.mkdir(parents=True,exist_ok=True)
        if len(arches)==1: shutil.copy2(binaries[arches[0]]/name,target)
        else: run(['lipo','-create',*[binaries[a]/name for a in arches],'-output',target])
    for name in ['lrz','lsz']:
        target=contents/'Helpers'/name
        if len(arches)==1: shutil.copy2(helpers[arches[0]]/name,target)
        else: run(['lipo','-create',*[helpers[a]/name for a in arches],'-output',target])
    (contents/'Helpers/rz').symlink_to('lrz'); (contents/'Helpers/sz').symlink_to('lsz')
    for bundle in binaries[arches[0]].glob('*.bundle'):
        shutil.copytree(bundle,resources/bundle.name)
    info=dict(INFO,LSMinimumSystemVersion=minimum)
    if INCLUDE_TESTS: info['OShellTestHarness'] = True
    (contents/'Info.plist').write_bytes(plistlib.dumps(info))
    bridge=contents/'Helpers/OShell-FileZilla.app'
    bridge_info=plistlib.loads((ROOT/'scripts/FileZilla-Info.plist').read_bytes());bridge_info['LSMinimumSystemVersion']=minimum
    (bridge/'Contents/Info.plist').write_bytes(plistlib.dumps(bridge_info))
    for source,name in [(ROOT/'LICENSE','OShell-LICENSE.txt'),(ROOT/'THIRD_PARTY_NOTICES.txt','THIRD_PARTY_NOTICES.txt'),(ROOT/'Vendor/SwiftTerm/LICENSE','SwiftTerm-LICENSE.txt'),(helpers[arches[0]].parent/'COPYING','lrzsz-COPYING.txt'),(ROOT/'Vendor/lrzsz-0.12.20.tar.gz','lrzsz-0.12.20.tar.gz')]: shutil.copy2(source,resources/name)
    shutil.copytree(ROOT/'Vendor/NerdFonts',resources/'NerdFonts')
    shutil.copytree(ROOT/'Vendor/DejaVuFonts',resources/'DejaVuFonts')
    if flavor=='legacy': shutil.copy2(ROOT/'Vendor/CryptoSwift/LICENSE',resources/'CryptoSwift-LICENSE.txt')
    shutil.copy2(ROOT/'shell-integration/oshell-integration.sh',resources/'oshell-integration.sh')
    shutil.copy2(ROOT/'Vendor/ColorSchemes/LICENSE',resources/'ColorSchemes-LICENSE.txt')
    # Generate from the canonical drawing code, never reuse an older app icon.
    run(['swift',ROOT/'scripts/icon.swift',WORK/'OShell.iconset'])
    run(['iconutil','-c','icns',WORK/'OShell.iconset','-o',resources/'OShell.icns'])
    if flavor=='legacy':
        frameworks=contents/'Frameworks';frameworks.mkdir()
        runtime=Path(output(['xcrun','--find','swiftc'])).parent.parent/'lib/swift-5.0/macosx'
        run(['xcrun','swift-stdlib-tool','--copy','--scan-folder',contents,'--platform','macosx','--source-libraries',runtime,'--destination',frameworks],log='package-legacy-runtime.log')
        assert (frameworks/'libswiftCore.dylib').exists(), 'Missing pre-Swift-OS runtime'
    entries=[]
    for path in sorted(contents.rglob('*')):
        if not macho(path):continue
        actual=output(['lipo','-archs',path]).split()
        assert set(arches).issubset(actual),(path,actual)
        if flavor=='legacy' and len(actual)>1:
            thin=path.with_suffix(path.suffix+'.thin')
            run(['lipo',path,'-thin','x86_64','-output',thin]);thin.replace(path)
        if path.relative_to(contents).parts[0] != 'Frameworks':
            run(['xcrun','strip','-S',path],log='package-strip-last.log')
        if path != contents/'MacOS/OShell':
            run(['codesign','--force','--sign','-',path],log='package-codesign-last.log')
        entries.append({'path':str(path.relative_to(app)),'architectures':arches,'build':output(['vtool','-show-build',path]),'libraries':output(['otool','-L',path])})
    run(['codesign','--force','--sign','-',bridge],log='package-codesign-last.log')
    run(['python3',ROOT/'scripts/embed-sparkle.py',app,*arches],log=f'package-{flavor}-sparkle.log')
    run(['python3',ROOT/'scripts/sign-app.py',app],log='package-codesign-last.log')
    run(['codesign','--verify','--deep','--strict',app])
    for path in (contents/'Frameworks/Sparkle.framework').rglob('*'):
        if macho(path): entries.append({'path':str(path.relative_to(app)),'architectures':arches,'build':output(['vtool','-show-build',path]),'libraries':output(['otool','-L',path])})
    run(['python3',ROOT/'scripts/check-public-source.py','--app',app],log=f'package-{flavor}-privacy.log')
    (LOG/f'package-{flavor}-binaries.json').write_text(json.dumps(entries,indent=2))
    return app

def package(flavor, arches, minimum, app, package_format="both"):
    if plistlib.loads((app/'Contents/Info.plist').read_bytes()).get('OShellTestHarness'):
        raise ValueError('Test applications cannot be packaged for release')
    run(['python3',ROOT/'scripts/check-public-source.py','--app',app],log=f'package-{flavor}-privacy.log')
    assert (app/'Contents/Resources/OShell-LICENSE.txt').read_bytes()==(ROOT/'LICENSE').read_bytes(), 'Rebuild the app with the project license before packaging'

    signature = code_signing.metadata(plistlib.loads((app/'Contents/Info.plist').read_bytes()))
    signing_label = '固定自签名证书' if signature['signing'] == 'self-signed' else '开发用 ad-hoc 签名'
    suffix=TARGETS[flavor].suffix
    base=f'OShell-{VERSION}-{suffix}'
    stage=WORK/flavor
    archlist=','.join(arches)
    artifacts=[]
    if package_format == 'both':
        payload=stage/'payload'
        if payload.exists(): shutil.rmtree(payload)
        payload.mkdir()
        shutil.copytree(app,payload/'OShell.app',dirs_exist_ok=True,symlinks=True)
        component=stage/'component.plist'
        run(['pkgbuild','--analyze','--root',payload,component],log=f'package-{flavor}-analyze.log')
        components=plistlib.loads(component.read_bytes())
        for item in components:item['BundleIsRelocatable']=False;item['BundleIsVersionChecked']=False;item['BundleOverwriteAction']='upgrade'
        component.write_bytes(plistlib.dumps(components))
        part=stage/'OShell-component.pkg'
        run(['pkgbuild','--compression','legacy','--root',payload,'--component-plist',component,'--identifier','app.oshell.mac','--version',VERSION,'--install-location','/Applications',part],log=f'package-{flavor}-component.log')
        distribution=stage/'Distribution.xml'
        distribution.write_text(f'''<?xml version="1.0" encoding="utf-8"?>
    <installer-gui-script minSpecVersion="2">
    <title>OShell {VERSION}</title>
    <options customize="never" require-scripts="false" rootVolumeOnly="true" hostArchitectures="{archlist}"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <volume-check><allowed-os-versions><os-version min="{minimum}"/></allowed-os-versions></volume-check>
    <choices-outline><line choice="default"/></choices-outline>
    <choice id="default" title="OShell"><pkg-ref id="app.oshell.mac"/></choice>
    <pkg-ref id="app.oshell.mac" version="{VERSION}" onConclusion="none">OShell-component.pkg</pkg-ref>
    </installer-gui-script>
    ''')
        pkg=OUT/(base+'.pkg')
        run(['productbuild','--distribution',distribution,'--package-path',stage,pkg],log=f'package-{flavor}-product.log')
        artifacts.append(pkg)
    image=stage/'image'
    if image.exists(): shutil.rmtree(image)
    image.mkdir()
    shutil.copytree(app,image/'OShell.app',dirs_exist_ok=True,symlinks=True)
    if not (image/'Applications').is_symlink():(image/'Applications').symlink_to('/Applications')
    pkg_hint='，或使用同版本 PKG 安装' if package_format == 'both' else ''
    (image/'安装说明.txt').write_text(f'OShell {VERSION}\n适用：macOS {minimum} 或更新版本；架构 {archlist}。\n把 OShell.app 拖入 Applications{pkg_hint}。\n各版本使用同一个应用及会话目录，只需安装适合本机的一种。\n本包使用{signing_label}，未进行 Developer ID 签名或 Apple 公证。\n构建校验不等同于最低系统的实际运行验证。\n包内 release-manifest.json 记录构建信息；SHA256SUMS.txt 校验包内文件，不包含外层 DMG 自身。\n')
    installer_metadata.write(image, version=VERSION, build=str(INFO['CFBundleVersion']), flavor=flavor, minimum=minimum, architectures=arches, source_root=ROOT)
    dmg=OUT/(base+'.dmg')
    run(['hdiutil','create','-ov','-format','UDZO','-fs','HFS+','-volname',f'OShell {VERSION}','-srcfolder',image,dmg],log=f'package-{flavor}-dmg.log')
    run(['hdiutil','verify',dmg],log=f'package-{flavor}-dmg-verify.log')
    artifacts.append(dmg)
    return artifacts

def main():
    global INCLUDE_TESTS, WORK
    parser=argparse.ArgumentParser();parser.add_argument('--flavor',choices=[*TARGETS, 'all'],default='all');parser.add_argument('--repository',help='Public GitHub owner/repo to embed as the default update source');parser.add_argument('--apps-only',action='store_true');parser.add_argument('--package-only',action='store_true');parser.add_argument('--format',choices=['both','dmg'],default='both');parser.add_argument('--test-core',action='store_true');parser.add_argument('--tests',action='store_true',help='Include isolated UI tests; requires --apps-only');args=parser.parse_args()
    if args.tests and not args.apps_only: parser.error('--tests requires --apps-only; test apps are never release packages')
    INCLUDE_TESTS = args.tests
    if INCLUDE_TESTS: WORK = ROOT/'work/test-release'
    if args.apps_only and args.package_only: parser.error('--apps-only and --package-only are mutually exclusive')
    if args.test_core and args.package_only: parser.error('--test-core requires a source build')
    if args.repository:
        import re
        if not re.fullmatch(r'[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*/[A-Za-z0-9_.-]+',args.repository): parser.error('Repository must be owner/repo')
        INFO['OShellUpdateRepository']=args.repository
    WORK.mkdir(parents=True,exist_ok=True);OUT.mkdir(parents=True,exist_ok=True);LOG.mkdir(exist_ok=True)
    artifacts=[]
    for flavor in (RELEASE_FLAVORS if args.flavor == 'all' else [args.flavor]):
        target=TARGETS[flavor];arches=list(target.architectures);minimum=target.minimum
        if args.package_only:
            app=WORK/flavor/'OShell.app'
            run(['codesign','--verify','--deep','--strict',app])
        else:
            binaries={a:build_swift(flavor,a,minimum) for a in arches}
            if args.test_core:
                run(core_check_command(binaries, platform.machine()),log=f'package-{flavor}-core.log')
            helpers={a:build_lrzsz(a,minimum) for a in arches}
            app=assemble(flavor,arches,minimum,binaries,helpers)
        print('Built application:',app,flush=True)
        if not args.apps_only:artifacts+=package(flavor,arches,minimum,app,args.format)
    if artifacts:
        checksum=OUT/'SHA256SUMS.txt'
        checksum.write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in sorted(OUT.glob('OShell-*')) if p.suffix in ['.pkg','.dmg']))
        for p in artifacts:print('Package:',p,flush=True)

if __name__=='__main__':main()
