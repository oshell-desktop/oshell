#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Compile unchanged published validators and prove the signed migration documents they accept."""
import argparse,base64,importlib.util,json,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('fixtures',ROOT/'scripts/test-update-migration.py');F=importlib.util.module_from_spec(spec);spec.loader.exec_module(F)

def main():
 p=argparse.ArgumentParser();p.add_argument('--bridge-source',type=Path,required=True);a=p.parse_args()
 fixture=F.MigrationTests();fixture.setUp()
 with tempfile.TemporaryDirectory(prefix='oshell-update-contract-') as temp:
  root=Path(temp);document=fixture.document();(root/'migration.json').write_text(json.dumps(document))
  for ref,flavors in [('v0.3.3',['arm64','intel','intelModern']),('v0.4.0',['arm64','amd64'])]:
   sources=[]
   for name in ['UpdateSource.swift','GitHubReleaseUpdate.swift']:
    path=root/name;path.write_bytes(subprocess.check_output(['git','show',f'{ref}:Sources/OShellCore/{name}'],cwd=ROOT));sources.append(path)
   (root/'error.swift').write_text('import Foundation\npublic enum ModelError:Error {case invalid(String)}\n')
   (root/'main.swift').write_text('''import Foundation
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let source = try UpdateSource(CommandLine.arguments[2])
for flavor: UpdateFlavor in ['''+','.join('.'+f for f in flavors)+'''] {
 let result = try GitHubReleaseUpdate.readStatic(data, source: source, flavor: flavor)
 precondition(result.version == "0.4.1" && result.build == "105")
}
print("PASS published validator")
''')
   run=['swiftc','-module-cache-path',str(root/'cache'),*map(str,sources),str(root/'error.swift'),str(root/'main.swift'),'-o',str(root/'check')]
   subprocess.run(run,check=True)
   for repo in F.M.REPOSITORIES:
    (root/'migration.json').write_text(json.dumps(fixture.document(repo)))
    subprocess.run([str(root/'check'),str(root/'migration.json'),repo],check=True)
   print(ref,'accepts all migration channels for both repositories',flush=True)
  source=a.bridge_source/'Sources/OShellCore/UpdateSource.swift';(root/'main.swift').write_text('''import Foundation
for os in [10,11,12,13,14,15,26,27] {
 for arm in [false,true] {
  let flavor = UpdateFlavor.select(appleSilicon:arm,majorOS:os)
  if os >= 15 { precondition(flavor.rawValue == (arm ? "macOS-arm64" : "macOS-amd64") && flavor.minimumOS == "15.0") }
  else { precondition(flavor != .modernARM && flavor != .modernAMD) }
 }
}
print("PASS bridge gates macOS 15 for both architectures")
''')
  subprocess.run(['swiftc','-module-cache-path',str(root/'cache'),str(source),str(root/'error.swift'),str(root/'main.swift'),'-o',str(root/'check')],check=True);subprocess.run([str(root/'check')],check=True)
if __name__=='__main__':main()
