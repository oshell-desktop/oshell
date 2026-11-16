#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Probe a real Codex client's closed-transport recovery, with no model or SSH.

Run with --codex /path/to/codex. Uses an isolated CODEX_HOME, an ephemeral
fixture thread and a synthetic MCP server; never connects to the user's daemon.
Only the fixture child is terminated, to reproduce a genuinely closed STDIO.
"""
import argparse,json,os,select,signal,subprocess,sys,tempfile,time
from pathlib import Path
if len(sys.argv)>1 and sys.argv[1]=='--fixture':
    root=Path(sys.argv[2]);(root/'helper.pid').write_text(str(os.getpid()))
    with (root/'starts').open('a') as f:f.write(str(os.getpid())+'\n')
    for line in sys.stdin:
        req=json.loads(line);method=req.get('method')
        if 'id' not in req:continue
        if method=='initialize':result={'protocolVersion':'2025-11-25','capabilities':{'tools':{}},'serverInfo':{'name':'recovery-fixture','version':'1'}}
        elif method=='tools/list':result={'tools':[{'name':'probe','description':'Read fixture PID only','inputSchema':{'type':'object'},'annotations':{'readOnlyHint':True}}]}
        elif method=='tools/call':result={'content':[{'type':'text','text':str(os.getpid())}],'isError':False}
        else:result={}
        print(json.dumps({'jsonrpc':'2.0','id':req['id'],'result':result}),flush=True)
    sys.exit()
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--codex',type=Path,required=True)
cli=str(parser.parse_args().codex.resolve(strict=True))
with tempfile.TemporaryDirectory(prefix='codex-mcp-recovery-',dir='/tmp') as raw:
    root=Path(raw);home=root/'home';home.mkdir();work=root/'workspace';work.mkdir()
    (home/'config.toml').write_text('model = "fixture"\nmodel_provider = "fixture"\n[model_providers.fixture]\nname = "Fixture"\nbase_url = "http://127.0.0.1:1/v1"\nwire_api = "responses"\n[mcp_servers.recovery_fixture]\ncommand = '+json.dumps(sys.executable)+'\nargs = '+json.dumps([str(Path(__file__).resolve()),'--fixture',str(root)])+'\n')
    env={k:v for k,v in os.environ.items() if not any(x in k.upper() for x in ['TOKEN','SECRET','PASSWORD','API_KEY'])}
    env.update(CODEX_HOME=str(home),HOME=str(root),NO_PROXY='127.0.0.1,localhost')
    log=(root/'stderr').open('w')
    p=subprocess.Popen([cli,'app-server'],env=env,cwd=work,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,bufsize=0)
    number=0;buffer=b'';events=[]
    def send(value):p.stdin.write(json.dumps(value).encode()+b'\n');p.stdin.flush()
    def rpc(method,params):
        global number,buffer
        number+=1;rid=number;send({'jsonrpc':'2.0','id':rid,'method':method,'params':params});deadline=time.monotonic()+20
        while time.monotonic()<deadline:
            if b'\n' not in buffer:
                if not select.select([p.stdout],[],[],max(0,deadline-time.monotonic()))[0]:break
                part=os.read(p.stdout.fileno(),65536)
                if not part:raise RuntimeError('app-server exited')
                buffer+=part;continue
            line,buffer=buffer.split(b'\n',1);msg=json.loads(line)
            if msg.get('id')==rid:return msg
            events.append(msg.get('method'))
        raise TimeoutError(method)
    results={}
    def report(name,value):
        results[name]=value
        print(json.dumps({'stage':name,'result':value},ensure_ascii=False),flush=True)
    try:
        report('initialize',rpc('initialize',{'clientInfo':{'name':'oshell_recovery_probe','version':'1'},'capabilities':{'experimentalApi':True}}))
        send({'jsonrpc':'2.0','method':'initialized'})
        reply=rpc('thread/start',{'cwd':str(work),'ephemeral':True,'approvalPolicy':'never','sandbox':'read-only'})
        if 'error' in reply:report('thread_error',reply);sys.exit(1)
        tid=reply['result']['thread']['id']
        status={'threadId':tid,'serverName':'recovery_fixture','detail':'toolsAndAuthOnly'}
        call={'threadId':tid,'server':'recovery_fixture','tool':'probe','arguments':{}}
        report('initial_status',rpc('mcpServerStatus/list',status))
        report('initial_call',rpc('mcpServer/tool/call',call))
        old=int((root/'helper.pid').read_text());os.kill(old,signal.SIGTERM);time.sleep(.3)
        report('call_after_fixture_exit',rpc('mcpServer/tool/call',call))
        report('status_after_fixture_exit',rpc('mcpServerStatus/list',status))
        report('call_after_status',rpc('mcpServer/tool/call',call))
        report('explicit_reload',rpc('config/mcpServer/reload',None))
        report('status_after_reload',rpc('mcpServerStatus/list',status))
        report('call_after_reload',rpc('mcpServer/tool/call',call))
        report('helper_starts',(root/'starts').read_text().splitlines())
        def helper_pid(stage):
            result=results[stage].get('result',{})
            assert not result.get('isError'),stage
            return int(result['content'][0]['text'])
        assert helper_pid('initial_call')==old
        assert 'result' in results['explicit_reload'], 'Official reload failed'
        assert helper_pid('call_after_reload')!=old, 'Closed helper was not replaced'
        # Observe rather than require the bug: future clients may auto-recover.
        report('summary',{'direct_call_auto_recovered':'result' in results['call_after_fixture_exit'],
                          'status_query_recovered':'result' in results['call_after_status'],
                          'official_reload_recovered':True,
                          'real_ssh_accessed':False,'model_called':False})
    finally:
        p.stdin.close()
        try:p.wait(5)
        except subprocess.TimeoutExpired:p.terminate();p.wait(5)
        log.close()
