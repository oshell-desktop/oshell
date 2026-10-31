#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Run native UI regressions in a disposable app and data directory."""
import argparse, json, os, plistlib, signal, subprocess, tempfile, uuid
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
CASES = {
 'focus-repaint':'OSHELL_FOCUS_REPAINT_OUTPUT',
 'font-library':'OSHELL_FONT_LIBRARY_OUTPUT',
 'interface-design':'OSHELL_INTERFACE_DESIGN_OUTPUT',
 'file-presentation':'OSHELL_FILE_PRESENTATION_OUTPUT',
 'agent-panel':'OSHELL_AGENT_PANEL_OUTPUT',
 'agent-resources':'OSHELL_AGENT_RESOURCES_OUTPUT',
 'agent-control':'OSHELL_AGENT_OUTPUT',
 'agent-replay':'OSHELL_AGENT_REPLAY_OUTPUT',
 'wheel-gestures':'OSHELL_WHEEL_OUTPUT',
 'fullscreen-activation':'OSHELL_FULLSCREEN_ACTIVATION_OUTPUT',
 'finder-service':'OSHELL_FINDER_SERVICE_OUTPUT',
 'activation-latency':'OSHELL_ACTIVATION_LATENCY_OUTPUT',
 'terminal-focus':'OSHELL_FOCUS_OUTPUT',
 'tiled-input':'OSHELL_TILED_INPUT_OUTPUT',
 'terminal-interrupt':'OSHELL_INTERRUPT_OUTPUT',
 'tab-session-info':'OSHELL_TAB_SESSION_INFO_OUTPUT',
 'marked-text':'OSHELL_MARKED_TEXT_OUTPUT',
 'metal-cursor':'OSHELL_METAL_CURSOR_OUTPUT',
 'image-paste':'OSHELL_IMAGE_PASTE_OUTPUT',
 'session-catalog-presentation':'OSHELL_CATALOG_PRESENTATION_OUTPUT',
 'tab-close-confirmation':'OSHELL_TAB_CLOSE_CONFIRMATION_OUTPUT',
 'session-pins':'OSHELL_SESSION_PINS_OUTPUT',
 'tab-title-settings':'OSHELL_TAB_TITLE_SETTINGS_OUTPUT',
 'tab-window-merge':'OSHELL_TAB_WINDOW_MERGE_OUTPUT',
 'auth-concurrency':'OSHELL_AUTH_CONCURRENCY_OUTPUT',
 'resource-review':'OSHELL_RESOURCE_REVIEW_OUTPUT',
 'tab-detach':'OSHELL_TAB_DETACH_OUTPUT',
 'sync-settings':'OSHELL_SYNC_SETTINGS_OUTPUT',
 'update-startup-state':'OSHELL_UPDATE_STARTUP_STATE_OUTPUT',
 'file-resume':'OSHELL_FILE_RESUME_OUTPUT',
 'file-transfer-history':'OSHELL_FILE_HISTORY_OUTPUT',
 'session-sidebar':'OSHELL_SIDEBAR_OUTPUT',
 'terminal-selection':'OSHELL_SELECTION_OUTPUT',
 'local-prompt-editing':'OSHELL_LOCAL_PROMPT_OUTPUT',
 'biometric-local-store':'OSHELL_BIOMETRIC_LOCAL_OUTPUT',
 'session-clipboard':'OSHELL_SESSION_CLIPBOARD_OUTPUT',
 'file-window-keyboard':'OSHELL_FILE_WINDOW_KEYS_OUTPUT',
 'readme-settings': 'OSHELL_README_SETTINGS_OUTPUT',
 'readme-screenshots': 'OSHELL_README_OUTPUT',
 'appearance': 'OSHELL_APPEARANCE_OUTPUT',
 'arrangement-scroll': 'OSHELL_ARRANGEMENT_SCROLL_OUTPUT',
 'automatic-biometric': 'OSHELL_AUTOMATIC_BIOMETRIC_OUTPUT',
 'biometric-unlock': 'OSHELL_BIOMETRIC_OUTPUT',
 'command-input': 'OSHELL_COMMAND_INPUT_OUTPUT',
 'directory-picker-stress': 'OSHELL_DIRECTORY_STRESS_OUTPUT',
 'directory-sync': 'OSHELL_DIRECTORY_SYNC_OUTPUT',
 'encrypted-startup': 'OSHELL_STARTUP_VAULT_OUTPUT',
 'ended-broadcast': 'OSHELL_ENDED_BROADCAST_OUTPUT',
 'session-inline-rename': 'OSHELL_SESSION_INLINE_RENAME_OUTPUT',
 'file-rate': 'OSHELL_FILE_RATE_OUTPUT',
 'file-metadata': 'OSHELL_FILE_METADATA_OUTPUT',
 'file-icons': 'OSHELL_FILE_ICONS_OUTPUT',
 'filetabs': 'OSHELL_FILETABS_OUTPUT',
 'focus-fullscreen': 'OSHELL_FOCUS_FULLSCREEN_OUTPUT',
 'idle-memory': 'OSHELL_IDLE_MEMORY_OUTPUT',
 'idle-tab-reuse': 'OSHELL_IDLE_TAB_OUTPUT',
 'keyboard-shortcuts': 'OSHELL_SHORTCUTS_OUTPUT',
 'layout': 'OSHELL_LAYOUT_OUTPUT',
 'links-catalog': 'OSHELL_LINKS_CATALOG_OUTPUT',
 'management': 'OSHELL_MANAGEMENT_OUTPUT',
 'master-removal': 'OSHELL_MASTER_REMOVAL_OUTPUT',
 'multi-window': 'OSHELL_MULTI_WINDOW_OUTPUT',
 'navigation-experience': 'OSHELL_NAVIGATION_OUTPUT',
 'operator-input': 'OSHELL_OPERATOR_OUTPUT',
 'pane-close': 'OSHELL_PANE_CLOSE_OUTPUT',
 'password-selection': 'OSHELL_PASSWORD_SELECTION_OUTPUT',
 'paste-scroll': 'OSHELL_PASTE_SCROLL_OUTPUT',
 'popup-keyboard': 'OSHELL_POPUP_OUTPUT',
 'global-proxy': 'OSHELL_GLOBAL_PROXY_OUTPUT',
 'proxy-catalog': 'OSHELL_PROXY_CATALOG_OUTPUT',
 'quicksend': 'OSHELL_QUICKSEND_OUTPUT',
 'quicksend-focus': 'OSHELL_QUICKSEND_FOCUS_OUTPUT',
 'session-password': 'OSHELL_SESSION_PASSWORD_OUTPUT',
 'login-password-save': 'OSHELL_LOGIN_SAVE_OUTPUT',
 'session-defaults': 'OSHELL_SESSION_DEFAULTS_OUTPUT',
 'session-directory': 'OSHELL_DIRECTORY_OUTPUT',
 'session-list': 'OSHELL_SESSION_LIST_ROOT',
 'shared-conflict': 'OSHELL_CONFLICT_OUTPUT',
 'startup-protection': 'OSHELL_STARTUP_PROTECTION_OUTPUT',
 'storage-sync': 'OSHELL_STORAGE_OUTPUT',
 'stress': 'OSHELL_STRESS_OUTPUT',
 'tab-bar-menu': 'OSHELL_TAB_BAR_MENU_OUTPUT',
 'tab-behavior': 'OSHELL_TAB_BEHAVIOR_OUTPUT',
 'tab-reorder': 'OSHELL_TAB_REORDER_OUTPUT',
 'tab-drag': 'OSHELL_TAB_DRAG_OUTPUT',
 'tab-number': 'OSHELL_TAB_NUMBER_OUTPUT',
 'terminal-chrome': 'OSHELL_CHROME_OUTPUT',
 'terminal-clock': 'OSHELL_CLOCK_OUTPUT',
 'terminal-scroller': 'OSHELL_SCROLLER_OUTPUT',
 'terminal-symbols': 'OSHELL_SYMBOLS_OUTPUT',
 'theme-audit': 'OSHELL_THEME_AUDIT_OUTPUT',
 'tunnel-ownership': 'OSHELL_TUNNEL_OWNERSHIP_OUTPUT',
 'unicode-display': 'OSHELL_UNICODE_OUTPUT',
 'update-feature': 'OSHELL_UPDATE_FEATURE_OUTPUT'}
CASES.update({
    'session-fullscreen':'OSHELL_FULLSCREEN_OUTPUT',
    'third-party-import':'OSHELL_EXTERNAL_IMPORT_OUTPUT',
    'session-links':'OSHELL_SESSION_LINKS_OUTPUT',
    'quicksend-groups':'OSHELL_QUICKSEND_GROUPS_OUTPUT',
    'quicksend-persistence':'OSHELL_QUICKSEND_PERSISTENCE_OUTPUT',
    'toolbar-actions':'OSHELL_TOOLBAR_ACTIONS_OUTPUT',
    'shell-integration':'OSHELL_SHELL_INTEGRATION_OUTPUT',
})
GROUPS = {
    'tabs': ['tab-behavior', 'layout', 'tab-number', 'tab-bar-menu', 'idle-tab-reuse'],
    'memory': ['idle-memory', 'metal-cursor', 'layout', 'ended-broadcast', 'stress'],
    'sessions': ['session-list', 'management', 'popup-keyboard', 'filetabs', 'session-directory', 'directory-picker-stress'],
}

def require_unlocked_desktop():
    tree = plistlib.loads(subprocess.check_output(['/usr/sbin/ioreg', '-a', '-n', 'Root', '-d', '1']))
    def locked(value):
        if isinstance(value, dict):
            if value.get('CGSSessionOnConsoleKey') is False: return False
            return value.get('CGSSessionScreenIsLocked') is True or any(locked(v) for v in value.values())
        if isinstance(value, list): return any(locked(v) for v in value)
        return False
    if locked(tree): raise RuntimeError('Desktop is locked; native fullscreen regression requires an unlocked desktop. No test app was launched.')

def run_case(source, case, timeout):
    info = plistlib.loads((source/'Contents/Info.plist').read_bytes())
    if info.get('OShellTestHarness') is not True:
        raise RuntimeError('Build the test app first: bash scripts/build.sh --tests')
    if case in ('fullscreen-activation', 'focus-fullscreen', 'session-fullscreen', 'focus-repaint'): require_unlocked_desktop()
    (ROOT/'work').mkdir(exist_ok=True); (ROOT/'validation').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='ui-check-', dir=ROOT/'work') as raw:
        base = Path(raw); app = base/'OShell UI Test.app'; data = base/'data'; data.mkdir()
        subprocess.run(['ditto', str(source), str(app)], check=True)
        bundle = 'app.oshell.ui-test.' + uuid.uuid4().hex
        info.update(CFBundleIdentifier=bundle, CFBundleName='OShell UI Test', CFBundleDisplayName='OShell UI Test')
        info.pop('SUDefaultsDomain', None)
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
        report = ROOT/'validation'/f'ui-{case}.json'; report.unlink(missing_ok=True)
        log = report.with_suffix('.log'); log.write_text('')
        ssh_fixture = None
        if case == 'agent-control' and os.environ.get('OSHELL_AGENT_SSH') == '1':
            import importlib.util
            spec = importlib.util.spec_from_file_location('agent_ssh', ROOT/'scripts/test-agent-ssh.py'); module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
            ssh_fixture = module.Fixture(data)
        destination = base/'results' if case == 'session-list' else report
        if case == 'session-list': destination.mkdir()
        args = ['open', '-n', '-W', '--env', 'OSHELL_DATA_DIR='+str(data), '--env', 'ZDOTDIR='+str(data), '--env', 'OSHELL_TEST_FONT_ROOT='+str(ROOT/'Vendor'),
                '--env', CASES[case]+'='+str(destination), '--stdout', str(log), '--stderr', str(log),
                str(app), '--args', '--'+case+'-test']
        if case == 'agent-control':
            args[1:1] = ['--env', 'OSHELL_AGENT_RUNNER='+str(ROOT/'scripts/test-agent-protocol.py'), '--env', 'OSHELL_AGENT_REAL_CLIENTS='+os.environ.get('OSHELL_AGENT_REAL_CLIENTS','0')]
            if os.environ.get('OSHELL_AGENT_REAL_CLIENTS') == '1': args[1:1] = ['--env', 'PATH='+os.environ.get('PATH','')]
        if case in ['activation-latency', 'fullscreen-activation'] and os.environ.get('OSHELL_ACTIVATION_METAL') == '1':
            args[1:1] = ['--env', 'OSHELL_ACTIVATION_METAL=1']
        if case == 'fullscreen-activation':
            peer = base/'ActivationPeer.app'; executable_dir = peer/'Contents/MacOS'; executable_dir.mkdir(parents=True)
            (peer/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier=bundle+'.peer', CFBundleExecutable='ActivationPeer', CFBundleName='ActivationPeer', CFBundlePackageType='APPL')))
            executable = executable_dir/'ActivationPeer'
            subprocess.run(['swiftc', str(ROOT/'scripts/activation-peer.swift'), '-o', str(executable)], check=True, capture_output=True)
            args[1:1] = ['--env', 'OSHELL_ACTIVATION_PEER='+str(executable)]
        try:
            subprocess.run(args, timeout=timeout, check=True, capture_output=True)
            if case == 'session-list': report.write_bytes((destination/'session-list-result.json').read_bytes())
            result = json.loads(report.read_text())
            if case == 'agent-control':
                if (data/'protocol.log').exists(): (ROOT/'validation/agent-protocol.log').write_bytes((data/'protocol.log').read_bytes())
                for client in ['codex','opencode']:
                    for name in ['client.log','observed.json','error.txt','request-error.txt']:
                        path=data/client/name
                        if path.exists(): (ROOT/'validation'/('agent-'+client+'-'+name)).write_bytes(path.read_bytes())
            if ssh_fixture is not None:
                result['checks']['sshAuthenticatedOnce'] = ssh_fixture.facts['authenticated'] == 1
                result['checks']['sshUsesOneVisiblePTYNoExec'] = ssh_fixture.facts['shells'] == 1 and ssh_fixture.facts['execRequests'] == 0
                report.write_text(json.dumps(result,ensure_ascii=False,indent=2))
            passed = result.get('passed', result.get('ok'))
            if case == 'stress': passed = result.get('samples', 0) > 0
            checks = result.get('checks', {})
            failures = [k for k,v in checks.items() if not v] if isinstance(checks, dict) else result.get('failures', [])
            if passed is not True or failures: raise RuntimeError(f'{case} failed: {failures}; see {log.relative_to(ROOT)}')
            print(f'{case}: passed', flush=True)
        finally:
            if ssh_fixture is not None: ssh_fixture.close()
            # Stop only this disposable clone on timeout; never kill the user's app.
            executable = str(app/'Contents/MacOS/OShell')
            for line in subprocess.check_output(['ps','-axo','pid=,comm='], text=True).splitlines():
                fields = line.strip().split(None, 1)
                if len(fields) == 2 and (fields[1] == executable or (case == 'fullscreen-activation' and fields[1] == str(base/'ActivationPeer.app/Contents/MacOS/ActivationPeer'))):
                    try: os.kill(int(fields[0]), signal.SIGTERM)
                    except ProcessLookupError: pass
            subprocess.run(['defaults','delete',bundle], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cases', nargs='*', choices=sorted(CASES))
    parser.add_argument('--group', choices=sorted(GROUPS))
    parser.add_argument('--list', action='store_true')
    parser.add_argument('--app', type=Path, default=ROOT/'work/test-app/OShell.app')
    parser.add_argument('--timeout', type=int, default=120)
    args = parser.parse_args()
    if args.list:
        print('\n'.join(sorted(CASES))); return
    selected = list(dict.fromkeys((GROUPS[args.group] if args.group else []) + args.cases))
    if not selected: parser.error('choose cases or --group; use --list to see available cases')
    for case in selected: run_case(args.app.resolve(), case, args.timeout)

if __name__ == '__main__': main()
