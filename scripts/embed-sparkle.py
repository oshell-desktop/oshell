#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""Embed the pinned updater preserving symlinks; thin/sign nested code inside-out."""
import argparse, pathlib, shutil, subprocess
ROOT=pathlib.Path(__file__).resolve().parent.parent
SOURCE=ROOT/'Vendor/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
def run(args): subprocess.run([str(x) for x in args],check=True,stdout=subprocess.DEVNULL)
def macho(path):
    if not path.is_file() or path.is_symlink(): return False
    with path.open('rb') as f: return f.read(4) in [b'\xcf\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca']
def remove_build_interfaces(framework):
    # Headers/module maps are used from Vendor during compilation, not at runtime.
    # Leave executable code, localization, licenses and the framework layout intact.
    versions = framework/'Versions'
    roots = [framework] + ([p for p in versions.iterdir() if p.is_dir() and not p.is_symlink()] if versions.is_dir() else [])
    for root in roots:
        for name in ('Headers', 'PrivateHeaders', 'Modules'):
            path = root/name
            if path.is_symlink(): path.unlink()
            elif path.is_dir(): shutil.rmtree(path)
def embed(app, arches):
    framework=app/'Contents/Frameworks/Sparkle.framework'
    if framework.exists(): shutil.rmtree(framework)
    framework.parent.mkdir(parents=True,exist_ok=True)
    shutil.copytree(SOURCE,framework,symlinks=True)
    remove_build_interfaces(framework)
    for path in framework.rglob('*'):
        if not macho(path): continue
        actual=subprocess.check_output(['lipo','-archs',str(path)],text=True).split()
        assert set(arches).issubset(actual)
        if len(arches)==1 and len(actual)>1:
            thin=path.with_name(path.name+'.thin')
            run(['lipo',path,'-thin',arches[0],'-output',thin]);thin.replace(path)
        run(['codesign','--force','--sign','-',path])
    bundles=sorted((p for p in framework.rglob('*') if p.is_dir() and not p.is_symlink() and p.suffix in ['.app','.xpc','.framework']),key=lambda p:len(p.parts),reverse=True)
    for bundle in bundles+[framework]: run(['codesign','--force','--sign','-',bundle])
    run(['codesign','--verify','--deep','--strict',framework])
    shutil.copy2(ROOT/'Vendor/Sparkle/LICENSE',app/'Contents/Resources/Sparkle-LICENSE.txt')
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('app',type=pathlib.Path);parser.add_argument('arches',nargs='+',choices=['arm64','x86_64'])
    args=parser.parse_args();embed(args.app,args.arches)
