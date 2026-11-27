#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Run native Swift/Go sync acceptance plus appearance boundary regressions.

The supplied Desktop source is copied into a disposable directory; its working
changes are never modified. All credentials and transport fixtures are synthetic.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--desktop-source', type=Path, required=True)
parser.add_argument('--output', type=Path, default=ROOT/'validation/appearance-interop.json')
args = parser.parse_args()
source = args.desktop_source.resolve()
with tempfile.TemporaryDirectory(prefix='oshell-appearance-interop-', dir='/tmp') as raw:
    work = Path(raw); desktop = work/'desktop'; desktop.mkdir()
    for name in ('go.mod','go.sum'): shutil.copyfile(source/name,desktop/name)
    for name in ('internal','third_party','scripts'):
        shutil.copytree(source/name,desktop/name,ignore=shutil.ignore_patterns('__pycache__','.DS_Store'))
    # The normal helper canonicalizes first. Also exercise raw Codable decoding,
    # which is the plaintext local-store entry point involved in the regression.
    helper = desktop/'scripts/interop/main.swift'; text = helper.read_text()
    anchor = 'if args[1] == "contract" {'
    if text.count(anchor) != 1: raise RuntimeError('Unsupported Desktop Swift helper layout')
    text = text.replace(anchor, '''if args[1] == "raw-model-json" {
 do {
  let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
  let config = try JSONDecoder().decode(Configuration.self, from: data)
  try JSONEncoder().encode(config).write(to: URL(fileURLWithPath: args[3]))
 } catch { fputs("Raw model rejected input\\n", stderr); exit(2) }
} else '''+anchor,1)
    helper.write_text(text)
    shutil.copyfile(ROOT/'scripts/fixtures/appearance-interop_test.go',desktop/'internal/core/appearance_validation_interop_test.go')
    env = dict(os.environ,GOCACHE=str(work/'go-cache'),GOMODCACHE=str(work/'go-mod-cache'))
    report = {'passed': False, 'commands': [], 'schemaSHA256': hashlib.sha256((desktop/'internal/core/shared_configuration_schema.json').read_bytes()).hexdigest()}
    digest=hashlib.sha256()
    for path in sorted((ROOT/'Sources/OShellCore').glob('*.swift')):
        digest.update(path.name.encode());digest.update(path.read_bytes())
    report['swiftCoreSHA256']=digest.hexdigest()
    commands = [
        ['python3','scripts/sync-configuration-contract.py','--native-source',str(ROOT),'--check'],
        ['go','test','./internal/core','-run','Test(NativeSwiftSharedFixture|SharedQuickSendScope|LegacySharedProtocol|SharedEncodingNormalization)','-count=1','-v'],
        ['python3','scripts/test-sync-interop.py','--native-source',str(ROOT)],
    ]
    try:
        for command in commands:
            print('RUN:', ' '.join(command),flush=True)
            result=subprocess.run(command,cwd=desktop,env=env)
            report['commands'].append({'command':command,'exitCode':result.returncode})
            result.check_returncode()
        report['passed']=True
    finally:
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
