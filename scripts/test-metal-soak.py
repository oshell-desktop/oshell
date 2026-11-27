#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Submit real offscreen Metal frames using production shaders and encoding.

No windows are shown. Temporary sources/binaries are removed on exit. This
checks rendering and resource lifetimes, not WindowServer presentation.
"""
import argparse, hashlib, json, os, pathlib, re, shutil, subprocess, tempfile, time

root = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--seconds-per-round', type=int, default=600)
parser.add_argument('--rounds', type=int, choices=range(2, 9), default=3)
parser.add_argument('--renderer-source', type=pathlib.Path, help='Use a saved renderer for before/after comparison')
parser.add_argument('--inflight-only', action='store_true', help='Gate three real GPU frames, release the renderer, then verify completed pixels')
parser.add_argument('--capture-leaks', action='store_true')
parser.add_argument('--fps', type=int, choices=range(1, 11), default=5)
parser.add_argument('--output', type=pathlib.Path, required=True)
args = parser.parse_args()
if args.inflight_only and args.capture_leaks: parser.error('Use --capture-leaks with the duration soak')
if not 10 <= args.seconds_per_round <= 3600: parser.error('seconds per round must be 10...3600')
with tempfile.TemporaryDirectory(prefix='oshell-metal-soak-', dir='/tmp') as raw:
    package = pathlib.Path(raw)
    source = package/'Sources/SwiftTerm'
    shutil.copytree(root/'Vendor/SwiftTerm/Sources/SwiftTerm', source)
    renderer = source/'Apple/Metal/MetalTerminalRenderer.swift'
    original = (args.renderer_source or renderer).read_text()
    renderer_hash = hashlib.sha256(original.encode()).hexdigest()
    kitty_hash = hashlib.sha256((source/'KittyGraphics.swift').read_bytes()).hexdigest()
    # Exercise the exact encoding sequence in draw(in:); fail closed if source
    # structure changes. Offscreen setup only replaces acquisition/presentation.
    begin = '        if let frame = drawData.frame {'
    end = '        encoder.endEncoding()'
    assert original.count(begin) == 1 and original.count(end) == 1
    encoding = original.split(begin, 1)[1].split(end, 1)[0]
    fixture = (root/'scripts/fixtures/metal-offscreen.swift').read_text() + '\n' + (root/'scripts/fixtures'/('metal-inflight.swift' if args.inflight_only else 'metal-soak.swift')).read_text()
    assert fixture.count('// PRODUCTION_ENCODING') == 1
    renderer.write_text(original + '\n' + fixture.replace('// PRODUCTION_ENCODING', begin + encoding))
    (package/'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SwiftTerm", platforms: [.macOS(.v15)],
    targets: [.executableTarget(name: "SwiftTerm", exclude: ["iOS", "Mac/README.md", "Documentation.docc"],
        resources: [.copy("Apple/Metal/Shaders.metal")])], swiftLanguageModes: [.v5])
''')
    command = ['swift', 'build', '--package-path', str(package), '--disable-sandbox', '-c', 'release', '-j', '2']
    subprocess.run(command, check=True)
    binary_dir = subprocess.check_output(command + ['--show-bin-path'], text=True).strip()
    args.output = args.output.resolve(); args.output.parent.mkdir(parents=True, exist_ok=True)
    command = ['nice', '-n', '10', str(pathlib.Path(binary_dir)/'SwiftTerm'), str(args.output),
               str(args.seconds_per_round), str(args.rounds), str(args.fps), "1" if args.capture_leaks else "0"]
    markers = [pathlib.Path(str(args.output)+'.scan-'+phase) for phase in ['closed_1', f'closed_{args.rounds}']]
    for marker in markers: marker.unlink(missing_ok=True)
    process = subprocess.Popen(command)
    captures = []; phases = set(); start = time.monotonic()
    try:
        while process.poll() is None:
            if time.monotonic()-start > (120 if args.inflight_only else args.rounds*(args.seconds_per_round+30)+120): raise TimeoutError('Metal soak timed out')
            if args.capture_leaks:
                try: report = json.loads(args.output.read_text())
                except (FileNotFoundError, json.JSONDecodeError): report = {}
                phase = report.get('samples', [{}])[-1].get('phase')
                if report.get('pid') == process.pid and phase in {'closed_1', f'closed_{args.rounds}'} and phase not in phases:
                    phases.add(phase); path = args.output.with_suffix('.'+phase+'.leaks.txt')
                    with path.open('w') as log:
                        job = subprocess.Popen(['leaks', '--forkCorpse', '--noContent', str(process.pid)], stdout=log, stderr=subprocess.STDOUT)
                    captures.append((phase, job, path))
                    try: job.wait(timeout=30)
                    except subprocess.TimeoutExpired: job.terminate(); job.wait(timeout=5)
                    pathlib.Path(str(args.output)+'.scan-'+phase).touch()
            time.sleep(.2)
        report = json.loads(args.output.read_text()); report['leaks'] = []
        report['rendererSHA256'] = renderer_hash; report['kittyGraphicsSHA256'] = kitty_hash
        for phase, job, path in captures:
            try: job.wait(timeout=30)
            except subprocess.TimeoutExpired: job.terminate(); job.wait(timeout=5)
            match = re.search(r'(\d+) leaks for (\d+) total leaked bytes', path.read_text())
            report['leaks'].append(dict(phase=phase, count=int(match[1]) if match else None, bytes=int(match[2]) if match else None, exitCode=job.returncode))
        if args.capture_leaks:
            report['checks']['leakScansCompleted'] = len(report['leaks']) == 2 and all(s['count'] is not None for s in report['leaks'])
            if report['checks']['leakScansCompleted']:
                report['checks']['leakScansNoGrowth'] = report['leaks'][-1]['bytes'] <= report['leaks'][0]['bytes']
        report['passed'] = report['passed'] and all(report['checks'].values()) and process.returncode == 0
        args.output.write_text(json.dumps(report, indent=2))
        if not report['passed']: raise SystemExit(1)
    finally:
        for marker in markers: marker.unlink(missing_ok=True)
        if process.poll() is None:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
        for _, job, _ in captures:
            if job.poll() is None: job.terminate(); job.wait(timeout=5)
