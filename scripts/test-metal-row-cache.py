#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Exercise the actual SwiftTerm renderer and Metal buffers without an onscreen window."""
import argparse, os, pathlib, shutil, subprocess, tempfile

root = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--renderer-source', type=pathlib.Path)
parser.add_argument('--expect-trim', action='store_true')
parser.add_argument('--output', type=pathlib.Path, required=True)
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='oshell-row-cache-') as raw:
    package = pathlib.Path(raw)
    source = package/'Sources/SwiftTerm'
    shutil.copytree(root/'Vendor/SwiftTerm/Sources/SwiftTerm', source)
    renderer = source/'Apple/Metal/MetalTerminalRenderer.swift'
    if args.renderer_source:
        shutil.copyfile(args.renderer_source, renderer)
    with renderer.open('a') as target:
        target.write('\n' + (root/'scripts/fixtures/metal-row-cache-check.swift').read_text())
    (package/'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SwiftTerm", platforms: [.macOS(.v15)],
    targets: [.executableTarget(name: "SwiftTerm", exclude: ["iOS", "Mac/README.md", "Documentation.docc"],
        resources: [.copy("Apple/Metal/Shaders.metal")])], swiftLanguageModes: [.v5])
''')
    command = ['swift', 'build', '--package-path', str(package), '--disable-sandbox', '-c', 'release']
    subprocess.run(command, check=True)
    binary_dir = subprocess.check_output(command + ['--show-bin-path'], text=True).strip()
    env = os.environ.copy()
    env['OSHELL_EXPECT_ROW_TRIM'] = '1' if args.expect_trim else '0'
    subprocess.run([str(pathlib.Path(binary_dir)/'SwiftTerm'), str(args.output.resolve())], env=env, check=True)
