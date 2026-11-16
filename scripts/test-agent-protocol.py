#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Exercises the actual bundled SDK STDIO server against a disposable OShell test window.
No model provider or real SSH credentials are used. Run through run-ui-tests.py agent-control.
"""
import argparse, base64, json, os, select, shlex, subprocess, time, uuid
from pathlib import Path

parser = argparse.ArgumentParser(); parser.add_argument('--fixture', type=Path, required=True)
root = parser.parse_args().fixture
config = json.loads((root/'fixture.json').read_text())
checks = {}

def check(name, value):
    checks[name] = bool(value)
    if not value: raise AssertionError(name)

def action(name, **extra):
    request = dict(id=str(uuid.uuid4()), action=name, **extra)
    temp = root/'action.tmp'; temp.write_text(json.dumps(request)); temp.replace(root/'action.json')
    limit = time.monotonic()+10
    while time.monotonic()<limit:
        if (root/'ack').exists():
            reply = (root/'ack').read_text()
            if reply == request['id']: return
            if reply.startswith('error:'): raise RuntimeError(reply)
        time.sleep(.03)
    raise TimeoutError(name)

class Client:
    def __init__(self, token=None, name='Codex', version='2025-11-25'):
        env = dict(os.environ, OSHELL_AGENT_SOCKET=config['socket'], OSHELL_AGENT_TOKEN=token or config['token'])
        self.process = subprocess.Popen([config['helper']], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, bufsize=0)
        self.counter=0; self.buffer=b''; self.responses={}
        response=self.rpc('initialize',dict(protocolVersion=version, capabilities={'experimental':{'fixture':{'enabled':True}}}, clientInfo=dict(name=name,version='fixture')))
        check(name+'Negotiation', response.get('result',{}).get('protocolVersion') in ['2024-11-05','2025-03-26','2025-06-18','2025-11-25'])
        self.send(dict(jsonrpc='2.0',method='notifications/initialized'))
    def send(self, message):
        self.process.stdin.write(json.dumps(message).encode()+b'\n'); self.process.stdin.flush()
    def rpc(self, method, params):
        self.counter+=1; number=self.counter
        self.send(dict(jsonrpc='2.0',id=number,method=method,params=params))
        return self.response(number)
    def response(self, number):
        if number in self.responses:return self.responses.pop(number)
        deadline=time.monotonic()+15
        while time.monotonic()<deadline:
            if b'\n' not in self.buffer:
                ready,_,_=select.select([self.process.stdout],[],[],max(0,deadline-time.monotonic()))
                if not ready: break
                chunk=os.read(self.process.stdout.fileno(),65536)
                if not chunk: raise RuntimeError('MCP helper exited')
                self.buffer+=chunk; continue
            line,self.buffer=self.buffer.split(b'\n',1)
            message=json.loads(line)
            if message.get('id')==number: return message
            if 'id' in message:self.responses[message['id']]=message
        raise TimeoutError('response')
    def tool(self,name,**arguments):
        reply=self.rpc('tools/call',dict(name=name,arguments=arguments))
        if 'error' in reply: return {'error':reply['error']}
        result=reply['result']; text=result['content'][0]['text']
        if result.get('isError'): return {'error':text}
        return json.loads(text)
    def close(self):
        self.process.stdin.close()
        try:self.process.wait(3)
        except subprocess.TimeoutExpired:self.process.terminate();self.process.wait(3)

def ready(c):
    deadline=time.monotonic()+10
    while time.monotonic()<deadline:
        state=c.tool('session_state',session_id=config['pane'])
        if state.get('shell_ready'):return
        time.sleep(.05)
    raise AssertionError('shell integration not ready: '+json.dumps(state,ensure_ascii=False))

def task(c):
    return c.tool('task_start',session_id=config['pane'],generation=config['generation'])['task_id']

def submit(c,t,command,key=None):
    return c.tool('command_submit',task_id=t,command=command,idempotency_key=key or str(uuid.uuid4()))

def wait(c,op,limit=137,timeout=15):
    cursor=0; data=b''; deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        reply=c.tool('operation_read',operation_id=op,cursor=cursor,limit=limit)
        if 'error' in reply: raise AssertionError(reply)
        chunk=base64.b64decode(reply['output_base64']); data+=chunk; cursor=reply['next_cursor']
        if reply['operation']['state']=='completed' and not chunk:
            return reply,data
        time.sleep(.03)
    raise TimeoutError(op)

if __name__ == "__main__":
    clients=[]
    try:
        c=Client();clients.append(c); ready(c)
        initial=c.tool('session_state',session_id=config['pane'])
        check('authorizationOwnsTerminalBetweenTasks',initial['occupied'] and not initial['task_active'])
        listing=c.tool('sessions_list');check('onlyAuthorizedSessionVisible',len(listing)==1 and listing[0]['session_id']==config['pane'])
        check('idleSessionAdvertisesShortcutReadiness',listing[0]['can_exec'] and initial['can_exec'] and initial['current_operation'] is None and initial['task_id'] is None)
        check('hiddenSameNameSessionDenied','error' in c.tool('session_state',session_id=config['hidden']))
        tools=c.rpc('tools/list',{})['result']['tools'];check('legacySevenToolsRetained',{'sessions_list','session_state','task_start','command_submit','operation_read','task_end','task_stop'}.issubset({t['name'] for t in tools}));check('shortcutToolAvailable',any(t['name']=='session_exec' for t in tools))
        bad=Client(token='invalid-pairing-token',name='Unpaired');clients.append(bad)
        check('credentialNotClientNameAuthorizes','error' in bad.tool('sessions_list'));bad.close();clients.remove(bad)
        second=Client(name='OpenCode',version='2025-06-18');clients.append(second)
        def quick(command, key=None, **extra):
            return c.tool('session_exec',session_id=config['pane'],generation=config['generation'],command=command,idempotency_key=key or str(uuid.uuid4()),**extra)
        key=str(uuid.uuid4()); q=quick('pwd',key,wait_ms=3000)
        check('shortcutCompletesAndReturnsTextOnce',q.get('completed') and 'output_text' in q and 'output_base64' not in q and q['next_action']=='none' and not q['has_more'])
        check('shortcutAutomaticallyEndsTask',not c.tool('session_state',session_id=config['pane'])['task_active'])
        check('shortcutIdempotencyAfterCompletion',quick('pwd',key)['operation']['operation_id']==q['operation']['operation_id'])
        check('shortcutChangedPayloadRejected','error' in quick('uptime',key))
        check('shortcutInvalidWaitDoesNotCreateTask','error' in quick('pwd',wait_ms=-1) and not c.tool('session_state',session_id=config['pane'])['task_active'])
        old=c.tool('operation_read',operation_id=q['operation']['operation_id'])
        check('legacyOutputStillContainsBothFormats',set(old)=={'operation','stream','next_cursor','durable_sequence','output_base64','output_text'} and base64.b64decode(old['output_base64']).decode()==q['output_text'])
        q=quick('printf "SHORTCUT_中文🙂"',wait_ms=2000)
        check('shortcutStillRequiresApproval',q['next_action']=='approve_in_oshell' and not q['completed'])
        state=c.tool('session_state',session_id=config['pane']);listing=c.tool('sessions_list')[0]
        check('pendingShortcutDiscoverableWithoutResubmission',state['current_operation']['operation_id']==q['operation']['operation_id'] and state['task_id']==q['task_id'] and listing['current_operation']['operation_id']==q['operation']['operation_id'] and listing['current_operation']['state']=='pending_approval')
        check('pendingApprovalIsNotShellReady',not state['can_exec'] and not state['shell_ready'] and not listing['can_exec'])
        check('approvalExplainsPolicyAndUserAction',q['approval']['reason']=='outside_automatic_policy' and q['approval']['permission']=='assist' and state['approval']==q['approval'])
        op=q['operation']['operation_id'];action('approve',operation=op)
        complete=c.tool('operation_read',operation_id=op,wait_ms=3000,wait_for='completion',format='compact')
        check('waitingReadCompletesApprovedShortcut',complete['completed'] and 'SHORTCUT_中文🙂' in complete['output_text'])
        check('finishedShortcutClearsPendingMetadata',complete['approval'] is None and c.tool('session_state',session_id=config['pane'])['current_operation'] is None)
        raw=c.tool('operation_read',operation_id=op);payload=base64.b64decode(raw['output_base64']);offset=payload.index('中'.encode())
        split=c.tool('operation_read',operation_id=op,cursor=offset,limit=1,format='compact')
        check('compactSplitUTF8PreservesRawBytes',split['encoding']=='base64' and 'output_text' not in split and base64.b64decode(split['output_base64'])==payload[offset:offset+1] and split['has_more'])
        q=quick('sleep 1; printf WAITED_DONE');op=q['operation']['operation_id'];action('approve',operation=op)
        before=time.monotonic();short=c.tool('operation_read',operation_id=op,wait_ms=120,wait_for='completion',format='compact')
        check('waitTimeoutDoesNotStopCommand',not short['completed'] and time.monotonic()-before>=.08)
        out=c.tool('operation_read',operation_id=op,cursor=short['next_cursor'],wait_ms=3000,format='compact')
        check('waitingReadWakesForNewOutput','WAITED_DONE' in out.get('output_text',''))
        wait(c,op)
        q=quick('sleep 30');op=q['operation']['operation_id'];action('approve',operation=op);time.sleep(.15)
        c.counter+=1;waiting=c.counter
        c.send(dict(jsonrpc='2.0',id=waiting,method='tools/call',params=dict(name='operation_read',arguments=dict(operation_id=op,wait_ms=10000,wait_for='completion',format='compact'))))
        time.sleep(.1);before=time.monotonic()
        stopped=c.tool('task_stop',task_id=q['task_id'],interrupt=True)
        check('waitingDoesNotBlockTaskStop',stopped.get('connection_preserved') and time.monotonic()-before<2)
        reply=c.response(waiting)['result'];check('stoppedCommandUnblocksWait',not reply.get('isError') and json.loads(reply['content'][0]['text'])['completed'])
        ready(c)
        q=quick('sleep 1; printf AFTER_CANCELLED_READ');op=q['operation']['operation_id'];action('approve',operation=op)
        c.counter+=1;cancelled_read=c.counter
        c.send(dict(jsonrpc='2.0',id=cancelled_read,method='tools/call',params=dict(name='operation_read',arguments=dict(operation_id=op,wait_ms=10000,wait_for='completion',format='compact'))))
        time.sleep(.1);before=time.monotonic()
        c.send(dict(jsonrpc='2.0',method='notifications/cancelled',params=dict(requestId=cancelled_read,reason='synthetic read cancellation')))
        cancelled=c.response(cancelled_read)['result']
        check('cancelWaitingReadReturnsPromptly',cancelled.get('isError') and time.monotonic()-before<2)
        result,data=wait(c,op)
        check('cancelWaitingReadDoesNotStopCommand',b'AFTER_CANCELLED_READ' in data and result['operation']['exit_code']==0)
        t=task(c);check('exclusiveWriter','error' in second.tool('task_start',session_id=config['pane'],generation=config['generation']))
        check('shortcutDoesNotStealLegacyTask','error' in quick('pwd'))
        key=str(uuid.uuid4());first=submit(c,t,'uptime',key);check('queryAutomaticallyAccepted',first.get('state') in ['persisting_intent','sent','running'])
        again=submit(c,t,'uptime',key);check('idempotencySameOperation',again['operation_id']==first['operation_id'])
        check('changedPayloadRejected','error' in submit(c,t,'pwd',key))
        result,data=wait(c,first['operation_id']);check('confirmedExitCode',result['operation']['exit_code']==0)
        check('commandEchoHasNoExecutionWrapper',b'eval --' not in data and b"printf '\\033]779" not in data)
        failed=submit(c,t,'false');action('approve',operation=failed['operation_id']);result,data=wait(c,failed['operation_id'])
        check('nonzeroExitPreserved',result['operation']['exit_code']==1)
        prior=submit(c,t,'printf "PRIOR_STATUS=%s\\n" "$__fixture_prompt_status"');action('approve',operation=prior['operation_id']);result,data=wait(c,prior['operation_id'])
        check('existingPromptHookReceivesExitCode',b'PRIOR_STATUS=1' in data)
        multiline=submit(c,t,'__fixture_value=multiline\ncd /tmp\nprintf "MULTI_%s\\n" "$__fixture_value"\nfalse')
        action('approve',operation=multiline['operation_id']);result,data=wait(c,multiline['operation_id'])
        check('multilineHasOneCompletion',b'MULTI_multiline' in data and result['operation']['exit_code']==1)
        stateful=submit(c,t,'printf "STATE=%s:%s\\n" "$PWD" "$__fixture_value"');action('approve',operation=stateful['operation_id']);result,data=wait(c,stateful['operation_id'])
        check('commandsRetainShellState',b'STATE=/tmp:multiline' in data)
        pipeline=submit(c,t,"printf '\\033[32m中文\\033[0m\\n' | cat")
        check('pipelineNeedsApproval',pipeline['state']=='pending_approval')
        action('human',value='HUMAN_MUST_NOT_INTERLEAVE')
        action('approve',operation=pipeline['operation_id']);result,data=wait(c,pipeline['operation_id'])
        check('ansiChineseIncrementalBytes','中文'.encode() in data and b'\x1b[32m' in data)
        check('manualInputBlockedDuringLease',b'HUMAN_MUST_NOT_INTERLEAVE' not in data)
        check('knownDangerBlocked','error' in submit(c,t,'rm -rf /'))
        check('interactiveRequiresHuman','error' in submit(c,t,'sudo true'))
        long=submit(c,t,"sleep 1; printf LONG_DONE")
        action('approve',operation=long['operation_id']);result,data=wait(c,long['operation_id']);check('longTaskRead',b'LONG_DONE' in data)
        bulk=submit(c,t, "/usr/bin/python3 -c " + shlex.quote('print("AUDIT_LOAD_"*200000)'))
        action('approve',operation=bulk['operation_id']);result,data=wait(c,bulk['operation_id'],limit=65536,timeout=60)
        check('largeOutputFullyArchivedAndRead',b'AUDIT_LOAD_'*200000 in data)
        compact=c.tool('operation_read',operation_id=bulk['operation_id'],format='compact',limit=65536)
        check('compactLargeUTF8ChunkReadableWithoutBase64',compact['encoding']=='utf8' and 'output_base64' not in compact and compact['has_more'] and compact['output_text'].encode()==data[:65536])
        legacy=c.tool('operation_read',operation_id=bulk['operation_id'],limit=65536)
        check('legacyLargeChunkEncodingUnchanged',legacy['output_text'] is None and base64.b64decode(legacy['output_base64'])==data[:65536])
        pending=submit(c,t,"printf STALE_MUST_NOT_EXECUTE")
        action('permission',value='ask');action('approve',operation=pending['operation_id'])
        read=c.tool('operation_read',operation_id=pending['operation_id']);check('permissionInvalidatesApproval',read['operation']['state']=='cancelled_before_send')
        ready(second);t2=task(second)
        query=submit(second,t2,'pwd');check('askRequiresApproval',query['state']=='pending_approval');action('approve',operation=query['operation_id']);wait(second,query['operation_id'])
        check('normalTaskEndPreservesConnection',second.tool('task_end',task_id=t2)['connection_preserved'])
        idle=second.tool('session_state',session_id=config['pane'])
        check('taskEndKeepsAccessAndShellReady',idle['occupied'] and idle['shell_ready'] and not idle['task_active'])
        action('human',value='HUMAN_BETWEEN_TASKS_MUST_NOT_INTERLEAVE')
        check('manualInputBlockedBetweenTasks','HUMAN_BETWEEN_TASKS_MUST_NOT_INTERLEAVE' not in second.tool('session_state',session_id=config['pane'])['screen'])
        ready(c);t3=task(c)
        long=submit(c,t3,'sleep 30');action('approve',operation=long['operation_id']);time.sleep(.3)
        stop=c.tool('task_stop',task_id=t3,interrupt=True);check('explicitStopKeepsConnection',stop['connection_preserved'])
        ready(c);t4=task(c)
        action('ctrl_c');check('ctrlCRevokesAccess',c.tool('sessions_list')==[])
        action('integrate');ready(c);t4=task(c)
        action('escape');check('doubleEscapeRevokesAccess',c.tool('sessions_list')==[])
        action('integrate');ready(c);t5=task(c)
        c.close();clients.remove(c);time.sleep(.5)
        disconnected=second.tool('session_state',session_id=config['pane'])
        check('clientExitKeepsAccessAndShellReady',disconnected['occupied'] and disconnected['shell_ready'] and not disconnected['task_active'])
        renewed=task(second);resumed=submit(second,renewed,'pwd');action('approve',operation=resumed['operation_id']);wait(second,resumed['operation_id'])
        second.tool('task_end',task_id=renewed)
        check('clientReconnectNeedsNoShellApproval',second.tool('session_state',session_id=config['pane'])['shell_ready'])
        detached_task=task(second);detached=submit(second,detached_task,'sleep 2; printf DETACHED_FINISHED')
        action('approve',operation=detached['operation_id']);time.sleep(.2)
        second.close();clients.remove(second)
        second=Client(name='Reconnected');clients.append(second)
        check('disconnectDoesNotReleaseRunningCommand','error' in second.tool('task_start',session_id=config['pane'],generation=config['generation']))
        result,data=wait(second,detached['operation_id'])
        check('disconnectedCommandStillReportsActualCompletion',b'DETACHED_FINISHED' in data and result['operation']['exit_code']==0)
        action('takeover');check('manualStopRemovesSessionAccess',second.tool('sessions_list')==[])
        action('human',value="printf 'HUMAN_AFTER_TAKEOVER\\n'\r");time.sleep(.2)
        action('integrate');ready(second)
        action('sensitive');time.sleep(.2)
        check('sensitiveScreenMasked','fixture-password-测试' not in second.tool('session_state',session_id=config['pane'])['screen'])
        if os.environ.get('OSHELL_AGENT_REAL_CLIENTS') == '1':
            import importlib.util
            spec=importlib.util.spec_from_file_location('agent_clients',Path(__file__).with_name('test-agent-clients.py')); module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
            checks.update(module.run_clients(root,config,action))
        action('integrate');ready(second);fault_task=task(second)
        action('audit_fail');time.sleep(.1)
        check('auditFailureStopsNewExecution','error' in submit(second,fault_task,'uptime'))
        fault_state=second.tool('session_state',session_id=config['pane'])
        check('auditFailureReleasesOnlyAutomation',not fault_state['occupied'] and bool(fault_state['audit_error']))
        action('human',value="printf 'POST_AUDIT_FAILURE\\n'\r");time.sleep(.2)
        check('manualTerminalSurvivesAuditFailure','POST_AUDIT_FAILURE' in second.tool('session_state',session_id=config['pane'])['screen'])
        action('generation');check('generationInvalidatesGrant',second.tool('sessions_list')==[])
    finally:
        for client in clients:
            try:client.close()
            except Exception:pass
        (root/'checks.json').write_text(json.dumps(checks,ensure_ascii=False,indent=2))
    print('PASS',len(checks),'protocol checks')
