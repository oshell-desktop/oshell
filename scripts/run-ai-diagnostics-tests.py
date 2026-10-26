#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Loopback-only diagnostic authorization test. The SSH server never runs commands."""
import importlib.util, json, os, plistlib, secrets, socket, subprocess, tempfile, threading, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import paramiko, re, sys
# Legacy flag now covers an explicit disconnect returning to the SAME prompt.
# Passive terminal capture cannot detect a silent, identical-prompt host switch.
OSC_ST = "--osc-st" in sys.argv
ECHO_ONLY = "--echo-only" in sys.argv
CONTEXT_MISMATCH = "--context-mismatch" in sys.argv
CONTEXT_LOSS = "--context-loss" in sys.argv
UNSAFE_TERMINAL = next((x for x in ["password-prompt","pending-input","alternate-screen","database-prompt"] if "--"+x in sys.argv), "")
NESTED = "--nested-terminal" in sys.argv or CONTEXT_LOSS or CONTEXT_MISMATCH
HISTORY_BINDING = "--history-binding" in sys.argv
FAILURE_RECORD = "--failure-record" in sys.argv
EXECUTION_WAIT = "--execution-wait" in sys.argv
FULL_ACCESS = "--full-access" in sys.argv
GLOBAL_READ_ONLY = "--global-read-only" in sys.argv
TASK_READ_ONLY = "--task-read-only" in sys.argv
DENY_OPERATION = "--deny-operation" in sys.argv
MUTATION = "--mutation" in sys.argv
EXTREME = "--extreme" in sys.argv
MUTATION_ID = 'command:' + json.dumps(['touch', '/tmp/oshell-synthetic'], separators=(',', ':')).replace('/', '\\/')
CHAT_CONTINUE = "--chat-continue" in sys.argv
DIRECT_ANSWER = "--direct-answer" in sys.argv or CHAT_CONTINUE
BACKGROUND = "--background" in sys.argv
PAUSE_RESUME = "--pause-resume" in sys.argv
STOPPED_RETRY = "--stopped-retry" in sys.argv
CONFIRM_RETRY = "--confirm-retry" in sys.argv or STOPPED_RETRY
CONTINUOUS = "--continuous" in sys.argv
DENY_SCOPE = "--deny-scope" in sys.argv
UNSAFE_PLAN = "--unsafe-plan" in sys.argv or EXTREME
MISSING_LOG = "--missing-log" in sys.argv
SERVICE_SCOPE = "--services" in sys.argv or MISSING_LOG or DENY_SCOPE or UNSAFE_PLAN or CONTINUOUS or PAUSE_RESUME
ROOT = Path(__file__).resolve().parent.parent
FAILURE_FIXTURE = json.loads((ROOT/"scripts/fixtures/ai-protocol-failure.json").read_text())
with tempfile.TemporaryDirectory(prefix='ai-diagnostics-', dir=ROOT/'work') as raw:
    base=Path(raw); data=base/'data'; data.mkdir(mode=0o700)
    listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen();port=listener.getsockname()[1]
    key=paramiko.RSAKey.generate(2048);password=secrets.token_urlsafe(24)
    (data/'known_hosts').write_text(f'[127.0.0.1]:{port} {key.get_name()} {key.get_base64()}\n')
    facts={'shellCommands':[], 'nextCommandAfter':time.monotonic(), 'auths':0,'connections':0,'shellInput':0,'execs':[],'requests':[],'commands':[],'queryCountsAtRequest':[],'contexts':[],'delays':[]};transports=[]
    current={'host':'ai-ssh','user':'fixture','cwd':'~'}
    def prompt():
        if CONTEXT_MISMATCH and facts['commands']: return b'[app@inner /srv/work]$ '
        return f"[{current['user']}@{current['host']} {current['cwd']}]$ ".encode()
    def execute_terminal(channel, line):
        query=line
        assert '/bin/sh -c' not in line and '__oshell_ai_' not in line and 'OShellAI=' not in line
        service="systemctl show --no-pager --property=Id,LoadState,ActiveState,SubState,Result,MainPID,ExecMainCode,ExecMainStatus,NRestarts,FragmentPath,ActiveEnterTimestamp -- 'nginx.service'"
        log="if test -f '/var/log/nginx/error.log' && test ! -L '/var/log/nginx/error.log'; then tail -c 24576 -- '/var/log/nginx/error.log'; else printf '%s\\n' 'Log path missing, not a regular file, or a symbolic link; no file read.'; false; fi"
        allowed=[service,log] if SERVICE_SCOPE else ['uname -srm','uptime']
        if CONTINUOUS: allowed += ['ps -eo pid,ppid,user,stat,pcpu,pmem,comm','ss -lnt','free -m','df -h -l','uptime']
        if FAILURE_RECORD: allowed=['uptime','free -m','df -h -l','ps -eo pid,ppid,user,stat,pcpu,pmem,comm']
        if MUTATION: allowed=["'touch' '/tmp/oshell-synthetic'"]
        assert query in allowed, query
        facts['commands'].append(query);facts['contexts'].append(dict(current));facts['delays'].append(time.monotonic()-facts['nextCommandAfter'])
        result='SYNTHETIC_SYSTEM' if query==allowed[0] else 'SYNTHETIC_LOAD'
        result+=f"\nCONTEXT host={current['host']} user={current['user']} cwd={current['cwd']}"
        code=1 if MISSING_LOG and query==allowed[1] else 0
        if code:result+='\nNo such file; query did not read the log.'
        if CONTEXT_LOSS or CONTEXT_MISMATCH:
            channel.sendall((result+'\r\n').encode())
            current.update(host='ai-ssh',user='fixture',cwd='~')
            channel.sendall(b'Connection to inner closed.\r\n'+prompt())
            facts['nextCommandAfter']=time.monotonic();return
        if ECHO_ONLY:
            payload=(query+'\r\n').encode()+prompt()
        elif OSC_ST:
            # Shell pre-exec / completion / directory hooks use ST, not BEL.
            # The client's old greedy OSC regex erased this entire result.
            payload=b'\x1b]133;C\x1b\\'+(result+'\r\n').encode()+b'\x1b]133;D;0\x1b\\\x1b]7;file://ai-ssh/fixture\x1b\\'+prompt()
        else:
            payload=(result+'\r\n').encode()+prompt()
        for block in [payload[:1],payload[1:12],payload[12:]]: channel.sendall(block)
        facts['nextCommandAfter']=time.monotonic()
    def shell(channel):
        try:
            time.sleep(.15);channel.sendall(b'\x1b[?2004h'+prompt());line=bytearray();escape=bytearray()
            while True:
                block=channel.recv(16384)
                if not block:break
                facts['shellInput']+=len(block);echo=bytearray()
                for byte in block:
                    if byte==27 or escape:
                        escape.append(byte)
                        if escape in (b'\x1b[200~',b'\x1b[201~'):escape.clear()
                        elif len(escape)>6:raise AssertionError('unexpected terminal escape')
                        continue
                    if byte==21:
                        line.clear();echo.extend(b'\r\x1b[2K'+prompt())
                    elif byte==13:
                        command=line.decode();line.clear();facts['shellCommands'].append(command)
                        channel.sendall(bytes(echo)+b'\r\n');echo.clear()
                        if command=='ssh middle':current.update(host='middle');channel.sendall(prompt())
                        elif command=='ssh inner':current.update(host='inner');channel.sendall(prompt())
                        elif command=='su app':current.update(user='app');channel.sendall(prompt())
                        elif command=='cd /srv/work':current.update(cwd='/srv/work');channel.sendall(prompt())
                        elif command:execute_terminal(channel,command)
                        else:channel.sendall(prompt())
                    elif byte>=32:
                        line.append(byte);echo.append(byte)
                if echo:channel.sendall(echo)
        except (EOFError,OSError): pass
        except Exception as error:
            facts['shellError']=type(error).__name__+': '+str(error)
            channel.close()
    class SSH(paramiko.ServerInterface):
        def check_auth_password(self,user,pw):
            if user=='ai-fixture' and pw==password:facts['auths']+=1;return paramiko.AUTH_SUCCESSFUL
            return paramiko.AUTH_FAILED
        def get_allowed_auths(self,user):return 'password'
        def check_channel_request(self,kind,chanid):return paramiko.OPEN_SUCCEEDED if kind=='session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        def check_channel_pty_request(self,*args):return True
        def check_channel_shell_request(self,channel):threading.Thread(target=shell,args=(channel,),daemon=True).start();return True
        def check_channel_exec_request(self,channel,command):
            cmd=command.decode();facts['execs'].append(cmd)
            return False
    def accept():
        try:
            while True:
                conn,_=listener.accept();facts['connections']+=1;t=paramiko.Transport(conn);transports.append(t);t.add_server_key(key);t.start_server(server=SSH())
        except Exception:pass
    threading.Thread(target=accept,daemon=True).start()
    class HTTP(BaseHTTPRequestHandler):
        def log_message(self,*args):pass
        def do_POST(self):
            value=json.loads(self.rfile.read(int(self.headers['Content-Length'])));facts['requests'].append(value)
            plan='serviceState:nginx.service\nlogTail:/var/log/nginx/error.log' if SERVICE_SCOPE else 'system\nload'
            if DENY_SCOPE: plan='serviceState:nginx.service\nlogTail:/var/log/unapproved/error.log'
            if UNSAFE_PLAN: plan='system;touch /tmp/not-authorized'
            if EXTREME: plan='command:' + json.dumps(['rm', '-rf', '/*'])
            if MUTATION: plan=MUTATION_ID
            count=len(facts['requests'])
            evidence=['serviceState:nginx.service','logTail:/var/log/nginx/error.log'] if SERVICE_SCOPE else ['system','load']
            facts['queryCountsAtRequest'].append(len(facts['commands']))
            if MUTATION: evidence=[MUTATION_ID]
            payload={'protocol':'oshell.task.v1','action':'query','summary':'Investigate next evidence','queries':plan.splitlines(),'evidence':[], 'reason':'Resume or verify synthetic evidence'}
            if FAILURE_RECORD:
                if count <= 2: text=FAILURE_FIXTURE['replies'][count-1]
                else:
                    if count==3: payload.update(queries=['load','memory'])
                    elif count==4: payload.update(action='blocked',queries=[],evidence=['load','memory'],summary='已取得负载与内存证据；请确认继续评估磁盘和进程。',reason='合成测试：等待用户继续')
                    elif count==5: payload.update(queries=['disks','processes'],evidence=['load','memory'])
                    else: payload.update(action='complete',queries=[],evidence=['load','memory','disks','processes'],summary='DIAGNOSTIC_COMPLETE：已根据负载、内存、磁盘和进程证据完成评估；缺少持续 I/O 采样，不能断言长期没有瓶颈。')
                    text=json.dumps(payload,ensure_ascii=False)
            elif DIRECT_ANSWER:
                payload.update(action='answer',queries=[],summary='DIRECT_ANSWER: uname -srm prints system, release and machine information.')
                text=json.dumps(payload)
            else:
                if CONTINUOUS and count <= 4:
                    choices=[evidence, ['processes','listeners'], ['memory','disks'], ['serviceState:nginx.service','load']]
                    payload['queries']=choices[count-1]
                elif not (count==1 or ((PAUSE_RESUME or CONFIRM_RETRY) and count==2)):
                    payload.update(action='complete',queries=[],summary='DIAGNOSTIC_COMPLETE',evidence=evidence)
                text=json.dumps(payload)
            facts['nextCommandAfter']=time.monotonic()
            body=json.dumps({'choices':[{'finish_reason':'stop','message':{'role':'assistant','content':text}}]}).encode()
            self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
    server=ThreadingHTTPServer(('127.0.0.1',0),HTTP);threading.Thread(target=server.serve_forever,daemon=True).start()
    app=base/'OShell Diagnostic Test.app';subprocess.run(['ditto',str(ROOT/'work/test-app/OShell.app'),str(app)],check=True)
    info=plistlib.load(open(app/'Contents/Info.plist','rb'));assert info.get('OShellTestHarness')
    bundle='app.oshell.diagnostics.'+uuid.uuid4().hex;info.update(CFBundleIdentifier=bundle, CFBundleName="OShell Diagnostic Test", CFBundleDisplayName="OShell Diagnostic Test");info.pop('SUDefaultsDomain',None)
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info));subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
    report=ROOT/('validation/ui-ai-osc-st.json' if OSC_ST else 'validation/ui-ai-echo-only.json' if ECHO_ONLY else 'validation/ui-ai-full-access-extreme.json' if FULL_ACCESS and EXTREME else 'validation/ui-ai-full-access.json' if FULL_ACCESS else 'validation/ui-ai-stopped-retry.json' if STOPPED_RETRY else 'validation/ui-ai-confirm-retry.json' if CONFIRM_RETRY else 'validation/ui-ai-context-mismatch.json' if CONTEXT_MISMATCH else 'validation/ui-ai-context-loss.json' if CONTEXT_LOSS else 'validation/ui-ai-'+UNSAFE_TERMINAL+'.json' if UNSAFE_TERMINAL else 'validation/ui-ai-nested-terminal.json' if NESTED else 'validation/ui-ai-history-binding.json' if HISTORY_BINDING else 'validation/ui-ai-chat-continue.json' if CHAT_CONTINUE else 'validation/ui-ai-failure-record.json' if FAILURE_RECORD else 'validation/ui-ai-mutation.json' if MUTATION else 'validation/ui-ai-global-readonly.json' if GLOBAL_READ_ONLY else 'validation/ui-ai-task-readonly.json' if TASK_READ_ONLY else 'validation/ui-ai-deny-operation.json' if DENY_OPERATION else 'validation/ui-ai-extreme.json' if EXTREME else 'validation/ui-ai-direct-answer.json' if DIRECT_ANSWER else 'validation/ui-ai-background.json' if BACKGROUND else 'validation/ui-ai-pause-resume.json' if PAUSE_RESUME else 'validation/ui-ai-continuous.json' if CONTINUOUS else 'validation/ui-ai-denied-scope.json' if DENY_SCOPE else 'validation/ui-ai-unsafe-plan.json' if UNSAFE_PLAN else 'validation/ui-ai-nginx-missing-log.json' if MISSING_LOG else 'validation/ui-ai-service-diagnostics.json' if SERVICE_SCOPE else 'validation/ui-ai-diagnostics.json');report.unlink(missing_ok=True)
    process=subprocess.Popen([str(app/'Contents/MacOS/OShell'),'--ai-diagnostics-test'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=dict(os.environ,OSHELL_DATA_DIR=str(data),OSHELL_AI_DIAGNOSTICS_OUTPUT=str(report),OSHELL_AI_FAILURE_FIXTURE=str(ROOT/'scripts/fixtures/ai-protocol-failure.json')))
    try:
        stdout,stderr=process.communicate(json.dumps(dict(echoOnly=ECHO_ONLY,executionWait=EXECUTION_WAIT,endpoint=f'http://127.0.0.1:{server.server_port}/v1',port=port,username='ai-fixture',password=password,serviceScope=SERVICE_SCOPE,missingLog=MISSING_LOG,denyScope=DENY_SCOPE,unsafePlan=UNSAFE_PLAN,continuous=CONTINUOUS,pauseResume=PAUSE_RESUME,confirmRetry=CONFIRM_RETRY,stoppedRetry=STOPPED_RETRY,background=BACKGROUND,directAnswer=DIRECT_ANSWER,globalReadOnly=GLOBAL_READ_ONLY,fullAccess=FULL_ACCESS,taskReadOnly=TASK_READ_ONLY,denyOperation=DENY_OPERATION,mutation=MUTATION,failureRecord=FAILURE_RECORD,chatContinue=CHAT_CONTINUE,historyBinding=HISTORY_BINDING,nestedTerminal=NESTED,contextLoss=CONTEXT_LOSS or CONTEXT_MISMATCH,unsafeTerminal=UNSAFE_TERMINAL)).encode(),timeout=150)
        (ROOT/'validation/ui-ai-diagnostics.log').write_bytes(stdout+stderr)
        result=json.loads(report.read_text());checks=result['checks']
        if UNSAFE_PLAN or DIRECT_ANSWER or UNSAFE_TERMINAL: checks['noApprovalOfferedForForbiddenOrChat']=not any(k.startswith('askShown-') for k in checks)
        checks['oneSSHAuthentication']=facts['auths']==1 and facts['connections']==1
        checks['queriesMatchAllowedTask']=len(facts['commands'])==(0 if DIRECT_ANSWER or DENY_OPERATION or UNSAFE_PLAN or UNSAFE_TERMINAL else 1 if ECHO_ONLY or DENY_SCOPE or MUTATION or CONTEXT_LOSS or CONTEXT_MISMATCH else 4 if FAILURE_RECORD else 8 if CONTINUOUS else 2)
        checks['noSSHExecChannels']=not facts['execs']
        checks['commandsWrittenToBoundTerminal']=[c for c in facts['shellCommands'] if c not in ['ssh middle','ssh inner','su app','cd /srv/work','']]==facts['commands']
        checks['noPrintfProtocolWrappers']=all(not any(marker in command for marker in ['OSHELL_QUERY_','OShellAI=','__oshell_ai_','/bin/sh -c']) for command in facts['shellCommands'])
        checks['executionWaitMatchesSetting']=all(delay>=8 for delay in facts['delays']) if EXECUTION_WAIT else (not facts['delays'] or any(delay<8 for delay in facts['delays']))
        checks['noShellFixtureErrors']='shellError' not in facts
        checks['sameInteractiveConnectionRetained']=facts['auths']==1 and facts['connections']==1
        checks['requestCountMatchesTask']=len(facts['requests'])==((2 if CHAT_CONTINUE else 1) if DIRECT_ANSWER else 1 if ECHO_ONLY or DENY_OPERATION or DENY_SCOPE or UNSAFE_PLAN or UNSAFE_TERMINAL or CONTEXT_LOSS or CONTEXT_MISMATCH else 6 if FAILURE_RECORD else 5 if CONTINUOUS else 3 if (PAUSE_RESUME or CONFIRM_RETRY) else 2)
        checks['resultsAutomaticallyReturnOnlyAfterCollection']=bool(facts['requests']) and 'SYNTHETIC_SYSTEM' not in json.dumps(facts['requests'][0]) and (len(facts['requests'])==(2 if CHAT_CONTINUE else 1) if ECHO_ONLY or DIRECT_ANSWER or DENY_OPERATION or DENY_SCOPE or UNSAFE_PLAN or UNSAFE_TERMINAL or CONTEXT_LOSS or CONTEXT_MISMATCH else len(facts['requests'])==(6 if FAILURE_RECORD else 5 if CONTINUOUS else 3 if (PAUSE_RESUME or CONFIRM_RETRY) else 2) and 'SYNTHETIC_SYSTEM' in json.dumps(facts['requests'][-1]))
        checks['taskObjectiveSurvivesEveryRound']=not (CONTINUOUS or PAUSE_RESUME) or all('我的 nginx 请求异常' in json.dumps(request,ensure_ascii=False) for request in facts['requests'])
        checks['oneCanonicalSystemProtocol']=all('oshell.task.v1' in r['messages'][0]['content'] and 'oshell-query' not in r['messages'][0]['content'] and 'oshell-plan' not in r['messages'][0]['content'] for r in facts['requests'])
        checks['rulesNotUserAttachments']=all('附件 · 只读排查规则' not in m.get('content','') for r in facts['requests'] for m in r['messages'] if m['role']=='user')
        if FAILURE_RECORD:
            checks['badRepliesNeverExecute']=facts['queryCountsAtRequest']==[0,0,0,2,2,4]
            checks['originalObjectiveAlwaysPresent']=all(FAILURE_FIXTURE['problem'] in json.dumps(r,ensure_ascii=False) for r in facts['requests'])
            checks['badChannelTextNotReplayed']='We shouldn' not in json.dumps(facts['requests']) and 'The prior commentary' not in json.dumps(facts['requests'])
        if HISTORY_BINDING: checks['boundHistorySentOnlyAfterConsent']='SYNTHETIC_OLD_HISTORY' in json.dumps(facts['requests'][0])
        if CONTEXT_MISMATCH: checks['samePromptDisconnectStopsTask']=len(facts['commands'])==1 and len(facts['requests'])==1
        if CONTEXT_LOSS: checks['noFallbackToOuterHost']=len(facts['commands'])==1 and len(facts['requests'])==1 and not facts['execs']
        if NESTED: checks['everyQueryRunsInNestedContext']=bool(facts['contexts']) and all(c==dict(host='inner',user='app',cwd='/srv/work') for c in facts['contexts'])
        if CONFIRM_RETRY:
            checks['retryWaitsForFreshConfirmation']=facts['queryCountsAtRequest']==[0,0,2]
            checks['retryKeepsOriginalObjective']=all('DIAGNOSTIC_SYNTHETIC_QUESTION' in json.dumps(r,ensure_ascii=False) for r in facts['requests'])
        if OSC_ST:
            sent = json.dumps(facts['requests'][-1], ensure_ascii=False)
            checks['oscWrappedOutputsReachModel'] = 'SYNTHETIC_SYSTEM' in sent and 'SYNTHETIC_LOAD' in sent
            checks['oscMetadataNotSentToModel'] = '133;C' not in sent and '133;D;0' not in sent and 'file://ai-ssh/fixture' not in sent
        if ECHO_ONLY:
            checks['echoOnlyStopsBeforeNextCommandOrRequest'] = len(facts['commands']) == 1 and len(facts['requests']) == 1
        checks['noSSHPasswordToAI']=password not in json.dumps(facts['requests'])
        result['passed']=all(checks.values());report.write_text(json.dumps(result,indent=2,ensure_ascii=False))
        if not result['passed']: print(json.dumps({'commandCount':len(facts['commands']),'requestCount':len(facts['requests']),'delays':facts['delays']},ensure_ascii=False), facts.get('shellError'))
        print(json.dumps({'passed':result['passed'],'checks':len(checks),'failed':[k for k,v in checks.items() if not v]}));assert result['passed']
    finally:
        if process.poll() is None:process.kill();process.communicate()
        listener.close();server.shutdown()
        for t in transports:t.close()
        subprocess.run(['defaults','delete',bundle],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
