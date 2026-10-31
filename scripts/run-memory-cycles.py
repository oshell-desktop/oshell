#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""Profile three rounds of disposable SSH sessions, including transient memory peaks.

Use --sessions 1 --lines 0 for connection overhead, or defaults for 48 sessions
with scrollback. --visible requires an unlocked desktop and presented Metal
frames; --fullscreen additionally exercises the system fullscreen window.
"""
import argparse, ctypes, json, os, pathlib, plistlib, re, secrets, signal, socket, subprocess, sys, tempfile, threading, time, uuid
import paramiko
project = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('label', nargs='?', default='memory-cycles')
parser.add_argument('--rounds', type=int, choices=range(1,4), default=3)
parser.add_argument('--sessions', type=int, choices=range(1,17), default=16)
parser.add_argument('--lines', type=int, default=3200)
parser.add_argument('--visible', action='store_true')
parser.add_argument('--fullscreen', action='store_true')
parser.add_argument('--capture-vm', action='store_true', help='Capture vmmap summaries before, during and after a >120 MiB peak')
parser.add_argument('--idle-seconds', type=int, default=0, help='Keep fixed SSH tabs idle this many seconds per round (requires --background-tabs)')
parser.add_argument('--background-tabs', action='store_true', help='Visit every tab, leave the remaining tabs hidden, then verify background output and input')
parser.add_argument('--editor', action='store_true', help='Open and cancel the new-session editor after each SSH connection settles')
parser.add_argument('--display-index', type=int, help='Run fullscreen/geometry tests on this NSScreen index; default keeps the current display')
parser.add_argument('--minimize', action='store_true', help='Minimize and restore connected background tabs, checking released surfaces and fresh rendering')
parser.add_argument('--steady-cursor', action='store_true', help='Use a steady cursor for the idle control experiment instead of a blinking cursor')
parser.add_argument('--geometry-cycles', type=int, choices=range(0,6), default=0, help='Repeat native fullscreen, rapid tab switches and return to the original window size')
parser.add_argument('--switch-count', type=int, choices=range(1,101), default=20, help='Tab switches per geometry cycle')
args = parser.parse_args()
if args.display_index is not None and (args.display_index < 0 or not (args.fullscreen or args.geometry_cycles)): parser.error('--display-index requires --fullscreen or --geometry-cycles and a nonnegative index')
if args.geometry_cycles and (args.fullscreen or args.minimize or not args.background_tabs or os.environ.get('OSHELL_MEMORY_SOFTWARE') == '1'): parser.error('--geometry-cycles requires Metal background tabs, starting in a normal window without --minimize')
if args.minimize and (args.fullscreen or not args.background_tabs): parser.error('--minimize requires --background-tabs without --fullscreen')
if not 0 <= args.idle_seconds <= 14400 or (args.idle_seconds and not args.background_tabs): parser.error('--idle-seconds requires --background-tabs and must be 0...14400')
if not 0 <= args.lines <= 10000: parser.error('--lines must be 0...10000')
if pathlib.Path(args.label).name != args.label: parser.error('label must be a filename')
label = args.label
if (args.fullscreen or args.geometry_cycles) and os.environ.get('OSHELL_MEMORY_PANEL')=='1': parser.error('A panel benchmark cannot exercise system fullscreen')
if args.visible or args.fullscreen or args.geometry_cycles:
    import importlib.util
    spec=importlib.util.spec_from_file_location('ui_checks',project/'scripts/run-ui-tests.py')
    ui_checks=importlib.util.module_from_spec(spec);spec.loader.exec_module(ui_checks)
    ui_checks.require_unlocked_desktop()
# Read only this disposable process; no heap contents, credentials or user data.
class ProcessUsage(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in
        'user system idle interrupts pageins wired rss footprint start exit childuser childsystem childidle childinterrupts childpageins childelapsed read write'.split()]
libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
with tempfile.TemporaryDirectory(prefix='oshell-memory-cycles-', dir='/tmp') as directory:
    root = pathlib.Path(directory).resolve(); key = paramiko.RSAKey.generate(2048); password = secrets.token_hex(20)
    listener = socket.socket(); listener.bind(('127.0.0.1', 0)); listener.listen(32); port = listener.getsockname()[1]
    facts = dict(authenticated=0, activeTransports=0, shells=0, connections=0, rejectedAuthentications=0); lock = threading.Lock()
    payload = ''.join(f'\x1b[3{i%7+1}m{i:04d} 主机内存测试 error warning '+ 'x'*100+'\x1b[0m\r\n' for i in range(args.lines)).encode() + b'MEMORY_OUTPUT_COMPLETE\r\n'
    if args.idle_seconds: payload += b'\x1b[2 q' if args.steady_cursor else b'\x1b[1 q'
    def session(channel, round_number):
        try:
            channel.sendall(payload)
            if args.background_tabs:
                channel.settimeout(0.1); pending = b''; background_sent = False
                while not channel.closed:
                    try: phase = json.loads((root/'phase.json').read_text())
                    except (FileNotFoundError, json.JSONDecodeError): phase = {}
                    if phase.get('phase') == f'background_{round_number}' and not background_sent:
                        channel.sendall(f'\r\nBG_LOG_{round_number} 中文后台日志\r\n'.encode()); background_sent = True
                    if phase.get('phase') == f'open_{round_number}':
                        channel.send_exit_status(0); return
                    try:
                        data = channel.recv(4096)
                        if not data: return
                        pending += data
                        while b'\r' in pending:
                            line, pending = pending.split(b'\r', 1)
                            for token in re.findall(rb'check_[0-9]+_[0-9]+', line):
                                channel.sendall(b'REPLY_' + token + b'\r\n')
                    except socket.timeout: pass
                return
            # End the remote shell after the app records its loaded state.
            # This exercises normal SSH EOF/exit, independently of keyboard routing.
            while True:
                if channel.closed: return
                try: phase = json.loads((root/'phase.json').read_text())
                except (FileNotFoundError, json.JSONDecodeError): phase = {}
                if phase.get('phase') == f'open_{round_number}':
                    channel.send_exit_status(0); return
                time.sleep(.05)
        except (EOFError, OSError): pass
        finally: channel.close()
    class Server(paramiko.ServerInterface):
        def get_allowed_auths(self, user): return 'password'
        def check_auth_password(self, user, value):
            if user != 'test' or value != password:
                with lock: facts['rejectedAuthentications'] += 1
                return paramiko.AUTH_FAILED
            with lock: facts['authenticated'] += 1
            return paramiko.AUTH_SUCCESSFUL
        def check_channel_request(self, kind, chanid): return paramiko.OPEN_SUCCEEDED if kind == 'session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        def check_channel_pty_request(self, *args): return True
        def check_channel_shell_request(self, channel):
            with lock:
                facts['shells'] += 1; round_number = (facts['shells']-1)//args.sessions+1
            threading.Thread(target=session, args=(channel,round_number), daemon=True).start(); return True
    def connection(sock):
        transport = paramiko.Transport(sock)
        with lock:
            facts['activeTransports'] += 1; facts['connections'] += 1
        try:
            transport.add_server_key(key); transport.start_server(server=Server()); channels=[]
            while transport.is_active():
                channel=transport.accept(1)
                if channel is not None: channels.append(channel)
        except (EOFError,OSError,paramiko.SSHException): pass
        finally:
            transport.close()
            with lock: facts['activeTransports'] -= 1
    def accept():
        while True:
            try: sock,_ = listener.accept()
            except OSError: return
            threading.Thread(target=connection,args=(sock,),daemon=True).start()
    threading.Thread(target=accept,daemon=True).start()
    (root/'fixture.json').write_text(json.dumps(dict(port=port,password=password))); (root/'fixture.json').chmod(0o600)
    (root/'known_hosts').write_text(f'[127.0.0.1]:{port} {key.get_name()} {key.get_base64()}\n')
    env=os.environ.copy(); env.update(OSHELL_DATA_DIR=str(root/'config'),ZDOTDIR=str(root/'config'),OSHELL_MEMORY_CYCLE_ROOT=str(root),OSHELL_MEMORY_SESSION_COUNT=str(args.sessions),OSHELL_MEMORY_ROUNDS=str(args.rounds))
    if args.fullscreen: env['OSHELL_MEMORY_FULLSCREEN']='1'
    if args.geometry_cycles:
        env['OSHELL_MEMORY_GEOMETRY_CYCLES']=str(args.geometry_cycles)
        env['OSHELL_MEMORY_SWITCH_COUNT']=str(args.switch_count)
    if args.display_index is not None: env['OSHELL_MEMORY_DISPLAY_INDEX']=str(args.display_index)
    if args.minimize: env['OSHELL_MEMORY_MINIMIZE']='1'
    if args.visible or args.fullscreen or args.geometry_cycles: env['OSHELL_MEMORY_REQUIRE_VISIBLE']='1'
    if args.editor: env['OSHELL_MEMORY_OPEN_EDITOR']='1'
    if args.background_tabs: env['OSHELL_MEMORY_BACKGROUND_TABS']='1'
    if args.idle_seconds: env['OSHELL_MEMORY_IDLE_SECONDS']=str(args.idle_seconds)
    app=None; target=None
    captures=[]; captured=set()
    bundle='app.oshell.memory-cycles.'+uuid.uuid4().hex
    try:
        source=pathlib.Path(os.environ.get('OSHELL_MEMORY_BINARY',str(project/'work/test-app/OShell.app/Contents/MacOS/OShell'))).resolve().parents[2]
        clone=root/'OShell Memory Test.app'
        subprocess.run(['ditto',str(source),str(clone)],check=True)
        info_path=clone/'Contents/Info.plist';info=plistlib.loads(info_path.read_bytes())
        if info.get('OShellTestHarness') is not True: raise ValueError('An explicit test app is required')
        info.update(CFBundleIdentifier=bundle,CFBundleName='OShell Memory Test',CFBundleDisplayName='OShell Memory Test')
        info.pop('SUDefaultsDomain',None);info_path.write_bytes(plistlib.dumps(info))
        subprocess.run(['codesign','--force','--sign','-',str(clone)],check=True,capture_output=True)
        binary=str(clone/'Contents/MacOS/OShell')
        timeline=[];phase='startup';last_phase_read=0.0
        with (project/'validation'/f'{label}.log').open('wb') as log:
            command=['open','-n','-W','--stdout',str(project/'validation'/f'{label}.log'),'--stderr',str(project/'validation'/f'{label}.log')]
            for name,value in env.items():
                if name.startswith('OSHELL_MEMORY_') or name in ('OSHELL_DATA_DIR','ZDOTDIR'):
                    command += ['--env',name+'='+value]
            command += [str(clone),'--args','--memory-cycles']
            app=subprocess.Popen(command,stdout=log,stderr=log)
            started=time.monotonic()
            while app.poll() is None:
                now=time.monotonic()
                if now-started>240+args.rounds*(args.idle_seconds+args.geometry_cycles*(35+args.switch_count*.5)): raise TimeoutError('SSH memory profile exceeded its run limit')
                if now-last_phase_read>.1:
                    try: phase=json.loads((root/'phase.json').read_text())['phase']
                    except (FileNotFoundError,json.JSONDecodeError): pass
                    last_phase_read=now
                if target is None:
                    for line in subprocess.check_output(['ps','-axo','pid=,comm='],text=True).splitlines():
                        parts=line.strip().split(None,1)
                        if len(parts)==2 and parts[1]==binary:
                            target=int(parts[0]); print(f'Test PID {target}; fixture {root}',flush=True)
                            if args.visible or args.fullscreen or args.geometry_cycles:
                                # Reopen the launched clone once so a visible test
                                # begins in the foreground even after a Space switch.
                                subprocess.run(['open','-a',str(clone)],check=True,capture_output=True)
                            break
                usage=ProcessUsage()
                if target is not None and libproc.proc_pid_rusage(target,2,ctypes.byref(usage))==0 and usage.footprint>0:
                    timeline.append([round(now-started,3),usage.rss,usage.footprint,phase])
                    capture = phase if args.geometry_cycles and phase.endswith('_immediate') else ('baseline' if phase=='startup' and now-started>1.2 else ('idle' if phase.endswith('_30s') else ('settled' if phase==f'closed_{args.rounds}' else ('peak' if usage.footprint>120*1048576 else None))))
                    if args.capture_vm and capture and capture not in captured:
                        captured.add(capture)
                        path=project/'validation'/f'{label}-{capture}.vmmap.txt'
                        with path.open('w') as output:
                            captures.append(subprocess.Popen(['vmmap','-summary',str(target)],stdout=output,stderr=subprocess.STDOUT))
                time.sleep(1 if phase.startswith('idle_') else .05)
        result=json.loads((root/'result.json').read_text()); time.sleep(1)
        result['server']=facts; result['checks']['allAuthenticated']=facts['authenticated']==args.sessions*args.rounds
        result['checks']['allTransportsClosed']=facts['activeTransports']==0
        result['highFrequency']=timeline; result['outputLinesPerSession']=args.lines; result['idleSecondsPerRound']=args.idle_seconds; result['rounds']=args.rounds
        result['idleCursorStyle']='steady' if args.steady_cursor else 'blinking'
        result['geometryCycles']=args.geometry_cycles
        result['testWindow']='panel' if env.get('OSHELL_MEMORY_PANEL')=='1' else 'workspace'
        if not timeline: raise RuntimeError('No per-process memory samples were available')
        result['peakFootprintMiB']=max(s[2] for s in timeline)/1048576
        # Presented frames prove earlier visibility; an end-of-phase sample may
        # be occluded after a dialog or another application covers the window.
        result['visibleRenderingObserved']=all(any(s.get('round')==r and any(s.get('metalFrames',[])) for s in result['samples']) for r in range(1,args.rounds+1))
        result['windowVisibilityObserved']=any(s.get('windowVisible') for s in result['samples']) or result['visibleRenderingObserved']
        if args.visible or args.fullscreen or args.geometry_cycles:
            result['checks']['visibleWindow']=result['windowVisibilityObserved']
        if (args.visible or args.fullscreen or args.geometry_cycles) and result['metal']:
            result['checks']['visibleMetalFrames']=result['visibleRenderingObserved']
        result['passed']=result['passed'] and all(result['checks'].values()) and app.returncode==0
        if not result['passed']:
            for log_file in root.glob('terminal-*.log'):
                (project/'validation'/f'{label}-{log_file.name}').write_text(log_file.read_text(errors='replace').replace(password, '[redacted]'))
        (project/'validation'/f'{label}.json').write_text(json.dumps(result,indent=2))
        print(json.dumps({k:v for k,v in result.items() if k!='highFrequency'},indent=2)); sys.exit(0 if result['passed'] else 1)
    finally:
        listener.close()
        for capture in captures:
            try: capture.wait(timeout=5)
            except subprocess.TimeoutExpired: capture.terminate(); capture.wait(timeout=5)
        if app is not None and app.poll() is None:
            # open(1) is only the launcher; terminate this clone, never the user's app.
            for line in subprocess.check_output(['ps','-axo','pid=,comm='],text=True).splitlines():
                parts=line.strip().split(None,1)
                if len(parts)==2 and parts[1]==str(root/'OShell Memory Test.app/Contents/MacOS/OShell'):
                    try: os.kill(int(parts[0]),signal.SIGTERM)
                    except ProcessLookupError: pass
            app.terminate()
            try: app.wait(timeout=5)
            except subprocess.TimeoutExpired: app.kill(); app.wait()
        subprocess.run(['defaults','delete',bundle],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
