#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Exercise native session-only behavior with unmodified Desktop core via a temporary Go overlay."""
import argparse, json, os, platform, subprocess, tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--desktop-source',type=Path,default=ROOT.parent/'oshell-desktop');args=parser.parse_args()
    if platform.system()!='Darwin':parser.error('The native Swift helper requires macOS')
    desktop=args.desktop_source.resolve()
    before=subprocess.check_output(['git','status','--porcelain'],cwd=desktop)
    subprocess.run(['python3',str(desktop/'scripts/sync-configuration-contract.py'),'--native-source',str(ROOT),'--check'],check=True)
    with tempfile.TemporaryDirectory(prefix='oshell-session-scope-') as temporary:
        work=Path(temporary);sources=sorted((ROOT/'Sources/OShellCore').glob('*.swift'))
        swift=['swiftc','-swift-version','5','-module-cache-path',str(work/'swift-cache')]
        subprocess.run(swift+['-emit-library','-emit-module','-module-name','OShellCore',*map(str,sources),'-o',str(work/'libOShellCore.dylib'),'-emit-module-path',str(work/'OShellCore.swiftmodule')],check=True)
        helper=work/'scope-check'
        subprocess.run(swift+['-I',str(work),'-L',str(work),'-lOShellCore','-Xlinker','-rpath','-Xlinker',str(work),str(ROOT/'Tests/SessionSyncInterop/main.swift'),'-o',str(helper)],check=True)
        virtual=desktop/'internal/core/zz_native_session_scope_external_test.go'
        if virtual.exists():raise RuntimeError('Overlay filename already exists')
        overlay=work/'overlay.json';overlay.write_text(json.dumps({'Replace':{str(virtual):str(ROOT/'Tests/SessionSyncInterop/interop_test.go')}}))
        env=dict(os.environ,OSHELL_SESSION_SCOPE_HELPER=str(helper),GOCACHE=str(work/'go-cache'))
        result=subprocess.run(['go','test','-mod=readonly','-overlay',str(overlay),'./internal/core','-run','^TestOShellSessionScopeCompatibility$','-count=1','-v'],cwd=desktop,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        print(result.stdout,end='')
        if result.returncode or '--- PASS: TestOShellSessionScopeCompatibility' not in result.stdout:raise RuntimeError('Native/Desktop scope test did not pass')
    if subprocess.check_output(['git','status','--porcelain'],cwd=desktop)!=before:raise RuntimeError('Desktop working tree changed during test')
    print('PASS: OShell session scope, unmodified Desktop interoperability, credentials, legacy data and no settings-only upload; Desktop source unchanged')
if __name__=='__main__':main()
