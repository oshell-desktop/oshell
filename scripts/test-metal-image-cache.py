#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Check image replacement in the actual private Metal texture/cache code."""
import argparse, pathlib, shutil, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--renderer-source', type=pathlib.Path, help='Baseline renderer before the image normalization helpers')
parser.add_argument('--output', type=pathlib.Path, required=True)
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='oshell-image-cache-', dir='/tmp') as raw:
    package = pathlib.Path(raw); source = package/'Sources/SwiftTerm'
    shutil.copytree(root/'Vendor/SwiftTerm/Sources/SwiftTerm', source)
    renderer = source/'Apple/Metal/MetalTerminalRenderer.swift'
    if args.renderer_source: shutil.copyfile(args.renderer_source, renderer)
    with renderer.open('a') as output: output.write('\n'+(root/'scripts/fixtures/metal-image-cache.swift').read_text())
    (package/'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SwiftTerm", platforms: [.macOS(.v15)],
    targets: [.executableTarget(name: "SwiftTerm", exclude: ["iOS", "Mac/README.md", "Documentation.docc"],
        resources: [.copy("Apple/Metal/Shaders.metal")])], swiftLanguageModes: [.v5])
''')
    command = ['swift','build','--package-path',str(package),'--disable-sandbox','-c','release','-j','2']
    if not args.renderer_source: command += ['-Xswiftc', '-DOSHELL_IMAGE_NORMALIZATION']
    subprocess.run(command,check=True)
    binary_dir = subprocess.check_output(command+['--show-bin-path'],text=True).strip()
    subprocess.run([str(pathlib.Path(binary_dir)/'SwiftTerm'),str(args.output.resolve())],check=True)
