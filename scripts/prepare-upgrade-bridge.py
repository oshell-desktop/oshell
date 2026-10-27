#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build and stage the explicitly pinned, one-time bridge from its separate checkout."""
import argparse,json,os,plistlib,shutil,subprocess,sys
from pathlib import Path
import update_migration as M

ROOT=Path(__file__).resolve().parent.parent

def run(args,cwd=None):subprocess.run(list(map(str,args)),cwd=cwd,check=True)
def main():
 p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True);p.add_argument('--flavor',choices=['arm64','legacy'],required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
 source=a.source.resolve();output=a.output.resolve()
 config=M.load_config(ROOT/'scripts/upgrade-bridge.json')
 commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=source,text=True).strip()
 if commit!=config['commit'] or subprocess.check_output(['git','status','--porcelain'],cwd=source):raise ValueError('Bridge checkout must exactly match its audited commit')
 info=plistlib.loads((source/'scripts/Info.plist').read_bytes())
 if (info['CFBundleShortVersionString'],str(info['CFBundleVersion']),info.get('OShellMigrationBridge'))!=(M.VERSION,M.BUILD,True):raise ValueError('Not the approved bridge version')
 run([sys.executable,'scripts/package-release.py','--flavor',a.flavor,'--format','dmg','--test-core'],source)
 run([sys.executable,'scripts/verify-installers.py','--flavor',a.flavor,'--format','dmg'],source)
 run([sys.executable,'scripts/ci-release.py','stage','--tag','v'+M.VERSION,'--build-only','--flavor',a.flavor,'--output',output],source)
 if a.flavor=='arm64':run([sys.executable,'scripts/export-public-source.py','--ref',commit,'--output',output/M.source_filename()],source)
 print('Verified bridge staged:',a.flavor,commit)
if __name__=='__main__':main()
