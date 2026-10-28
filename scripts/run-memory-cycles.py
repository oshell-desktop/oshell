#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""Profile three rounds of disposable SSH sessions, including transient memory peaks.

Use --sessions 1 --lines 0 for connection overhead, or defaults for 48 sessions
with scrollback. --visible requires an unlocked desktop and presented Metal
frames; --fullscreen additionally exercises the system fullscreen window.
"""
import argparse, ctypes, json, os, pathlib, plistlib, secrets, signal, socket, subprocess, sys, tempfile, threading, time, uuid
import paramiko
project = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('label', nargs='?', default='memory-cycles')
parser.add_argument('--sessions', type=int, choices=range(1,17), default=16)
parser.add_argument('--lines', type=int, default=3200)
parser.add_argument('--visible', action='store_true')
parser.add_argument('--fullscreen', action='store_true')
parser.add_argument('--capture-vm', action='store_true', help='Capture vmmap summaries before, during and after a >120 MiB peak')
parser.add_argument('--editor', action='store_true', help='Open and cancel the new-session editor after each SSH connection settles')
args = parser.parse_args()
if not 0 <= args.lines <= 10000: parser.error('--lines must be 0...10000')
if pathlib.Path(args.label).name != args.label: parser.error('label must be a filename')
label = args.label
if args.fullscreen and os.environ.get('OSHELL_MEMORY_PANEL')=='1': parser.error('A panel benchmark cannot exercise system fullscreen')
if args.visible or args.fullscreen:
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
    facts = dict(authenticated=0, activeTransports=0, shells=0); lock = threading.Lock()
    payload = ''.join(f'\x1b[3{i%7+1}m{i:04d} 主机内存测试 error warning '+ 'x'*100+'\x1b[0m\r\n' for i in range(args.lines)).encode() + b'MEMORY_OUTPUT_COMPLETE\r\n'
    def session(channel, round_number):
        try:
            channel.sendall(payload)
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
            if user != 'test' or value != password: return paramiko.AUTH_FAILED
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
        with lock: facts['activeTransports'] += 1
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
    env=os.environ.copy(); env.update(OSHELL_DATA_DIR=str(root/'config'),ZDOTDIR=str(root/'config'),OSHELL_MEMORY_CYCLE_ROOT=str(root),OSHELL_MEMORY_SESSION_COUNT=str(args.sessions))
    if args.fullscreen: env['OSHELL_MEMORY_FULLSCREEN']='1'
    if args.editor: env['OSHELL_MEMORY_OPEN_EDITOR']='1'
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
                if now-started>240: raise TimeoutError('SSH memory profile exceeded 240 seconds')
                if now-last_phase_read>.1:
                    try: phase=json.loads((root/'phase.json').read_text())['phase']
                    except (FileNotFoundError,json.JSONDecodeError): pass
                    last_phase_read=now
                if target is None:
                    for line in subprocess.check_output(['ps','-axo','pid=,comm='],text=True).splitlines():
                        parts=line.strip().split(None,1)
                        if len(parts)==2 and parts[1]==binary:
                            target=int(parts[0]); print(f'Test PID {target}; fixture {root}',flush=True); break
                usage=ProcessUsage()
                if target is not None and libproc.proc_pid_rusage(target,2,ctypes.byref(usage))==0 and usage.footprint>0:
                    timeline.append([round(now-started,3),usage.rss,usage.footprint,phase])
                    capture = 'baseline' if phase=='startup' and now-started>1.2 else ('peak' if usage.footprint>120*1048576 else ('settled' if phase=='closed_3' else None))
                    if args.capture_vm and capture and capture not in captured:
                        captured.add(capture)
                        path=project/'validation'/f'{label}-{capture}.vmmap.txt'
                        with path.open('w') as output:
                            captures.append(subprocess.Popen(['vmmap','-summary',str(target)],stdout=output,stderr=subprocess.STDOUT))
                time.sleep(.01)
        result=json.loads((root/'result.json').read_text()); time.sleep(1)
        result['server']=facts; result['checks']['allAuthenticated']=facts['authenticated']==args.sessions*3
        result['checks']['allTransportsClosed']=facts['activeTransports']==0
        result['highFrequency']=timeline; result['outputLinesPerSession']=args.lines
        result['testWindow']='panel' if env.get('OSHELL_MEMORY_PANEL')=='1' else 'workspace'
        if not timeline: raise RuntimeError('No per-process memory samples were available')
        result['peakFootprintMiB']=max(s[2] for s in timeline)/1048576
        # Presented frames prove earlier visibility; an end-of-phase sample may
        # be occluded after a dialog or another application covers the window.
        result['visibleRenderingObserved']=all(any(s.get('round')==r and any(s.get('metalFrames',[])) for s in result['samples']) for r in range(1,4))
        result['windowVisibilityObserved']=any(s.get('windowVisible') for s in result['samples']) or result['visibleRenderingObserved']
        if args.visible or args.fullscreen:
            result['checks']['visibleWindow']=result['windowVisibilityObserved']
        if (args.visible or args.fullscreen) and result['metal']:
            result['checks']['visibleMetalFrames']=result['visibleRenderingObserved']
        result['passed']=result['passed'] and all(result['checks'].values()) and app.returncode==0
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
