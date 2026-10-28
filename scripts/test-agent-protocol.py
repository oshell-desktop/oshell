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
        self.counter=0; self.buffer=b''
        response=self.rpc('initialize',dict(protocolVersion=version, capabilities={'experimental':{'fixture':{'enabled':True}}}, clientInfo=dict(name=name,version='fixture')))
        check(name+'Negotiation', response.get('result',{}).get('protocolVersion') in ['2024-11-05','2025-03-26','2025-06-18','2025-11-25'])
        self.send(dict(jsonrpc='2.0',method='notifications/initialized'))
    def send(self, message):
        self.process.stdin.write(json.dumps(message).encode()+b'\n'); self.process.stdin.flush()
    def rpc(self, method, params):
        self.counter+=1; number=self.counter
        self.send(dict(jsonrpc='2.0',id=number,method=method,params=params))
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
        raise TimeoutError(method)
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
    raise AssertionError('shell integration not ready')

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

clients=[]
try:
    c=Client();clients.append(c); ready(c)
    listing=c.tool('sessions_list');check('onlyAuthorizedSessionVisible',len(listing)==1 and listing[0]['session_id']==config['pane'])
    check('hiddenSameNameSessionDenied','error' in c.tool('session_state',session_id=config['hidden']))
    tools=c.rpc('tools/list',{})['result']['tools'];check('exactlySevenTools',len(tools)==7)
    bad=Client(token='invalid-pairing-token',name='Unpaired');clients.append(bad)
    check('credentialNotClientNameAuthorizes','error' in bad.tool('sessions_list'));bad.close();clients.remove(bad)
    second=Client(name='OpenCode',version='2025-06-18');clients.append(second)
    t=task(c);check('exclusiveWriter','error' in second.tool('task_start',session_id=config['pane'],generation=config['generation']))
    key=str(uuid.uuid4());first=submit(c,t,'uptime',key);check('queryAutomaticallyAccepted',first.get('state') in ['persisting_intent','sent','running'])
    again=submit(c,t,'uptime',key);check('idempotencySameOperation',again['operation_id']==first['operation_id'])
    check('changedPayloadRejected','error' in submit(c,t,'pwd',key))
    result,data=wait(c,first['operation_id']);check('confirmedExitCode',result['operation']['exit_code']==0)
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
    pending=submit(c,t,"printf STALE_MUST_NOT_EXECUTE")
    action('permission',value='ask');action('approve',operation=pending['operation_id'])
    read=c.tool('operation_read',operation_id=pending['operation_id']);check('permissionInvalidatesApproval',read['operation']['state']=='cancelled_before_send')
    action('integrate');ready(second);t2=task(second)
    query=submit(second,t2,'pwd');check('askRequiresApproval',query['state']=='pending_approval');action('approve',operation=query['operation_id']);wait(second,query['operation_id'])
    check('normalTaskEndPreservesConnection',second.tool('task_end',task_id=t2)['connection_preserved'])
    action('integrate');ready(c);t3=task(c)
    long=submit(c,t3,'sleep 30');action('approve',operation=long['operation_id']);time.sleep(.3)
    stop=c.tool('task_stop',task_id=t3,interrupt=True);check('explicitStopKeepsConnection',stop['connection_preserved'])
    time.sleep(.3);action('integrate');ready(c);t4=task(c)
    action('escape');check('doubleEscapeReleasesOwnership',not c.tool('session_state',session_id=config['pane'])['occupied'])
    action('integrate');ready(c);t5=task(c)
    c.close();clients.remove(c);time.sleep(.5)
    check('clientExitReleasesButSessionLives',not second.tool('session_state',session_id=config['pane'])['occupied'])
    action('human',value="printf 'HUMAN_AFTER_TAKEOVER\\n'\r");time.sleep(.2)
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
