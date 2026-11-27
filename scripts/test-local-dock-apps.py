#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Run after build.sh and build.sh --tests, on an unlocked macOS desktop."""
import os
import json
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
REGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'


def run(*args):
    return subprocess.check_output(list(map(str, args)), text=True).strip()


def wait_for(read, expected):
    deadline = time.monotonic() + 15
    while True:
        actual = read()
        if actual == expected:
            return
        if time.monotonic() >= deadline:
            raise AssertionError(f'{read.__name__}: expected {expected}, got {actual}')
        time.sleep(.12)


def process_id(executable):
    for line in run('ps', '-axo', 'pid=,comm=').splitlines():
        pid, path = line.strip().split(None, 1)
        if path == str(executable):
            return int(pid)
    return None


def test(folder):
    harness = ROOT/'work/test-app/OShell.app/Contents'
    if plistlib.loads((harness/'Info.plist').read_bytes()).get('OShellTestHarness') is not True:
        raise RuntimeError('The local shortcut fixture requires build.sh --tests')
    domain = 'app.oshell.ui-test.' + uuid.uuid4().hex
    home = folder/'home'
    home.mkdir()
    project = home/'sample project'
    project.mkdir()
    (home/'.zshenv').write_text('print -r -- "$PPID $PWD" >> "$ZDOTDIR/shells"\ncd -- "$ZDOTDIR/sample project"\n')
    palette = dict(id="custom-dock-test", name="Dock fixture", background="#123456", foreground="#EECCAA",
                   cursor="#00EE88", cursorText="#123456", selection="#335511", selectionText="#EEEEEE",
                   ansi=["#334455"] * 16)
    (home/'configuration.json').write_text(json.dumps(dict(profiles=[], preferences=dict(
        fontName="Menlo-Regular", fontSize=16, interfaceTheme="light", colorSchemeID=palette['id'], customColorSchemes=[palette]))))
    fonts = folder/'fixture-fonts/DejaVuFonts'
    fonts.mkdir(parents=True)
    shutil.copy2(ROOT/'Vendor/DejaVuFonts/DejaVuSansMono.ttf', fonts)
    host = folder/'OShell.app'
    terminal = folder/'oTerm.app'
    host_exe = host/'Contents/MacOS/OShell'
    term_exe = terminal/'Contents/MacOS/oTerm'
    for app in (host, terminal):
        run('ditto', ROOT/'dist'/app.name, app)
        plist = app/'Contents/Info.plist'
        info = plistlib.loads(plist.read_bytes())
        info.update(LSEnvironment=dict(HOME=str(home), CFFIXED_USER_HOME=str(home), OSHELL_DATA_DIR=str(home), ZDOTDIR=str(home), OSHELL_DOCK_TEST_ROOT=str(home)))
        if app == host:
            info.update(CFBundleIdentifier=domain, OShellLocalTerminalBundleIdentifier=domain+'.terminal')
            info.pop('NSServices', None)
            info['LSEnvironment']['OSHELL_TEST_FONT_ROOT'] = str(fonts.parent)
            # Launch Services may propagate the initiating fixture's environment.
            # Both disposable executables must accept the isolated test session.
            shutil.copy2(harness/'MacOS/OShell', host_exe)
        else:
            info.update(CFBundleIdentifier=domain+'.terminal', OShellHostBundleIdentifier=domain)
            shutil.copy2(harness/'MacOS/OShell', term_exe)
        plist.write_bytes(plistlib.dumps(info))
        run('codesign', '--force', '--sign', '-', app)

    # Count only titled OShell windows owned by the disposable process.
    source = folder/'probe.swift'
    source.write_text('''import AppKit
let pid = Int32(CommandLine.arguments[1])!
if CommandLine.arguments.dropFirst(2).first == "quit" {
    NSRunningApplication(processIdentifier: pid)?.terminate()
} else {
    let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String:Any]] ?? []
    print(windows.filter {
        guard $0[kCGWindowOwnerPID as String] as? Int32 == pid,
              $0[kCGWindowLayer as String] as? Int == 0,
              let title = $0[kCGWindowName as String] as? String else { return false }
        return title.hasPrefix("本地终端 · ") || title == "OShell" || title.hasSuffix("— OShell")
    }.count)
}
''')
    probe = folder/'probe'
    run('xcrun', 'swiftc', source, '-o', probe)

    def shells():
        log = home/'shells'
        return log.read_text().splitlines() if log.exists() else []

    try:
        # A Mac upgraded from the color-only build may start the terminal first.
        legacy = json.dumps({'interface': 'dark', 'scheme': palette}).encode().hex()
        subprocess.run(['defaults','write',domain+'.terminal-appearance','activeTheme.v1','-data',legacy],
                       env=dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home)), check=True)
        run('open', terminal)
        wait_for(lambda: len(shells()), 1)
        owner = process_id(term_exe)
        assert owner and int(shells()[0].split()[0]) == owner and process_id(host_exe) is None
        wait_for(lambda: run(probe, owner), '1')
        def shortcut(key):
            report = home/'shortcut-result'
            report.unlink(missing_ok=True)
            (home/'shortcut').write_text(key)
            wait_for(lambda: report.read_text() if report.exists() else '', key)
        def display_report(key):
            report = home/'shortcut-result'
            report.unlink(missing_ok=True)
            (home/'shortcut').write_text(key)
            wait_for(report.exists, True)
            return report.read_text()
        def theme_report(): return display_report('theme')
        def font_report(): return display_report('font')
        shortcut('t')  # ⌘T
        wait_for(lambda: len(shells()), 2)
        assert shells()[1] == f'{owner} {project}'
        assert run(probe, owner) == '1'
        wait_for(theme_report, 'dark:#123456,#123456')
        legacy_fonts = font_report().split(',')
        assert len(legacy_fonts) == 2 and all(face.endswith('@13') for face in legacy_fonts)
        system_face = legacy_fonts[0].rsplit('@', 1)[0]
        shortcut('N')  # ⇧⌘N
        wait_for(lambda: process_id(host_exe) is not None, True)
        workspace = process_id(host_exe)
        wait_for(lambda: run(probe, workspace), '1')
        wait_for(theme_report, 'light:#123456,#123456')
        wait_for(font_report, 'Menlo-Regular@16,Menlo-Regular@16')
        run('open', terminal)
        shortcut('N')
        wait_for(lambda: (home/'shortcut').exists(), False)
        time.sleep(.6)
        assert process_id(host_exe) == workspace and run(probe, workspace) == '1'
        assert run(probe, owner) == '1' and len(shells()) == 2
        # The exported local entry routes through the running workspace.
        request = folder/'local.oshellwindow'
        request.write_text('local-terminal\n')
        run('open', '-a', host, request)
        wait_for(lambda: len(shells()), 3)
        assert shells()[-1].startswith(f'{owner} ')
        wait_for(lambda: run(probe, owner), '2')
        original_shells = shells()
        (home/'font-change').write_text('size')
        wait_for(font_report, ','.join(['Menlo-Regular@20'] * 3))
        (home/'font-change').write_text('face')
        wait_for(font_report, ','.join(['DejaVuSansMono@20'] * 3))
        (home/'font-change').write_text('default')
        wait_for(font_report, ','.join([system_face + '@20'] * 3))
        (home/'font-change').write_text('face')
        wait_for(font_report, ','.join(['DejaVuSansMono@20'] * 3))
        assert shells() == original_shells
        run(probe, workspace, 'quit')
        wait_for(lambda: process_id(host_exe), None)
        assert process_id(term_exe) == owner and run(probe, owner) == '2'
        # Cold routing must retire the orange app after delivering its request.
        run('open', '-a', host, request)
        wait_for(lambda: len(shells()), 4)
        wait_for(lambda: process_id(host_exe), None)
        wait_for(lambda: run(probe, owner), '3')
        run('open', host, '--args', '-OShell.window.startWithLocalTerminal', 'YES')
        wait_for(lambda: len(shells()), 5)
        wait_for(lambda: process_id(host_exe), None)
        wait_for(lambda: run(probe, owner), '4')
        wait_for(theme_report, 'light:' + ','.join(['#123456'] * 5))
        wait_for(font_report, ','.join(['DejaVuSansMono@20'] * 5))
        def quit_terminal():
            pid = process_id(term_exe)
            (home/'shortcut').write_text('exit-shells')
            wait_for(lambda: subprocess.run(['pgrep', '-P', str(pid), '-x', 'zsh'],
                                            stdout=subprocess.DEVNULL).returncode, 1)
            run(probe, pid, 'quit')
            wait_for(lambda: process_id(term_exe), None)
        quit_terminal()
        run('open', terminal)
        wait_for(lambda: len(shells()), 6)
        wait_for(theme_report, 'light:#123456')
        assert process_id(host_exe) is None
        wait_for(font_report, 'DejaVuSansMono@20')
        quit_terminal()
        run('open', '-a', terminal, project)
        wait_for(lambda: len(shells()), 7)
        assert shells()[-1] == f'{process_id(term_exe)} {project}'
        wait_for(font_report, 'DejaVuSansMono@20')
        assert run(probe, process_id(term_exe)) == '1'
        print('Passed legacy theme, live font-only and size-only changes across windows, imported face, new windows and terminal-only relaunch.')
        print('Passed separate Dock ownership, tab CWD, workspace shortcut, window reuse, cold and warm forwarding, independent quit.')
    finally:
        for path in (host_exe, term_exe):
            pid = process_id(path)
            if pid: os.kill(pid, signal.SIGTERM)
        for app in (host, terminal):
            subprocess.run([REGISTER, '-u', app], capture_output=True)
        for identifier in (domain, domain+'.terminal', domain+'.terminal-appearance'):
            subprocess.run(['defaults', 'delete', identifier], capture_output=True)


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(dir=ROOT/'work', prefix='ui-check-') as raw:
        test(Path(raw))
