#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Real CLI clients driven by a deterministic loopback model; no provider secrets or real data."""
import json, os, shutil, subprocess, threading, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def run_clients(root, fixture, action):
    results = {}
    repository = Path(__file__).resolve().parent.parent
    binaries = {'codex': shutil.which('codex'), 'opencode': str(repository/'work/agent-clients/node_modules/.bin/opencode')}
    for kind, executable in binaries.items():
        if not executable or not Path(executable).exists():
            results[kind+'RealClientAvailable'] = False; continue
        action('permission', value='assist'); action('integrate'); time.sleep(.2)
        directory = root/kind; directory.mkdir(mode=0o700)
        observed = {'phase':0, 'calls':[], 'completed':False, 'task':None, 'operation':None, 'failure':None}
        def objects(value):
            if isinstance(value,dict):
                yield value
                for child in value.values(): yield from objects(child)
            elif isinstance(value,list):
                for child in value: yield from objects(child)
            elif isinstance(value,str) and value[:1] in ['{','[']:
                try: yield from objects(json.loads(value))
                except (ValueError,RecursionError): pass
        class Handler(BaseHTTPRequestHandler):
            protocol_version='HTTP/1.1'
            def log_message(self,*args): pass
            def do_GET(self):
                body=json.dumps({'object':'list','data':[{'id':'fixture','object':'model'}]}).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
            def do_POST(self):
                raw=self.rfile.read(int(self.headers['Content-Length']))
                if self.headers.get('Content-Encoding') == 'zstd':
                    binary=shutil.which('zstd')
                    if binary:raw=subprocess.run([binary,'-d','-c'],input=raw,stdout=subprocess.PIPE,check=True).stdout
                try:body=json.loads(raw)
                except Exception:
                    (directory/'request-error.txt').write_text(repr(dict(self.headers))+repr(raw[:80]));raise
                all_objects=list(objects(body))
                for obj in all_objects:
                    if 'task_id' in obj and isinstance(obj['task_id'],str):observed['task']=obj['task_id']
                    if 'operation_id' in obj and isinstance(obj['operation_id'],str):observed['operation']=obj['operation_id']
                phase=observed['phase']
                has_tools=bool(body.get('tools'))
                choices=[('sessions_list',{}),('session_state',{'session_id':fixture['pane']}),('task_start',{'session_id':fixture['pane'],'generation':fixture['generation']}),('command_submit',{'task_id':observed['task'],'command':"printf 'CLIENT_中文\\n'; sleep 0.2",'idempotency_key':kind+'-'+str(uuid.uuid4())})]
                tool=None;args={};namespace=None
                if phase==3 and any(o.get('state')=='waiting_for_shell_integration_approval' for o in all_objects):
                    action('integrate');time.sleep(.2)
                if not has_tools:pass
                elif phase<4:tool,args=choices[phase];observed['phase']+=1
                elif phase==4 and len(observed['calls']) < 80:
                    pending=any(o.get('state')=='pending_approval' for o in all_objects)
                    completed=any(o.get('state')=='completed' and o.get('operation_id')==observed['operation'] for o in all_objects)
                    if pending and not observed.get('approved'):
                        action('approve',operation=observed['operation']);observed['approved']=True
                    if completed:
                        observed['completed']=True;tool='task_end';args={'task_id':observed['task']};observed['phase']=5
                    else:tool='operation_read';args={'operation_id':observed['operation']};time.sleep(.06)
                if tool:
                    # Both clients expose normal MCP names in the model tool schemas.
                    definitions=list(objects(body.get('tools',[])))
                    names=[o.get('name','') for o in definitions if isinstance(o.get('name'),str)]
                    group=next((o for o in definitions if o.get('type')=='namespace' and 'oshell' in o.get('name','') and any(t.get('name')==tool for t in o.get('tools',[]))),None)
                    if group:namespace=group['name'];name=tool
                    else:name=next((n for n in names if n.endswith(tool) and ('oshell' in n.lower())),None)
                    if name is None:
                        observed['failure']='missing model tool '+tool+' in '+repr(names[:40]); name=('mcp__oshell__' if kind=='codex' else 'oshell_')+tool
                    observed['calls'].append(tool); callid='call_'+str(uuid.uuid4()).replace('-',''); arguments=json.dumps(args,ensure_ascii=False)
                else:name=None
                self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Connection','close');self.end_headers()
                def send(data,event=None):
                    payload=(('event: '+event+'\n') if event else '')+'data: '+json.dumps(data,ensure_ascii=False)+'\n\n';self.wfile.write(payload.encode());self.wfile.flush()
                if self.path.endswith('/responses'):
                    rid='resp_'+uuid.uuid4().hex
                    response={'id':rid,'object':'response','created_at':int(time.time()),'model':'fixture','status':'in_progress','output':[]}
                    send({'type':'response.created','response':response},'response.created')
                    if name:
                        item={'id':'fc_'+uuid.uuid4().hex,'type':'function_call','call_id':callid,'name':name,'arguments':arguments,'status':'completed'}
                        if namespace:item['namespace']=namespace
                        send({'type':'response.output_item.added','output_index':0,'item':dict(item,arguments='',status='in_progress')},'response.output_item.added')
                        send({'type':'response.function_call_arguments.delta','output_index':0,'item_id':item['id'],'delta':arguments},'response.function_call_arguments.delta')
                        send({'type':'response.function_call_arguments.done','output_index':0,'item_id':item['id'],'arguments':arguments},'response.function_call_arguments.done')
                    else:
                        item={'id':'msg_'+uuid.uuid4().hex,'type':'message','role':'assistant','status':'completed','content':[{'type':'output_text','text':'OSHELL_CLIENT_FIXTURE_PASS','annotations':[]}]}
                        send({'type':'response.output_item.added','output_index':0,'item':dict(item,content=[])},'response.output_item.added')
                        send({'type':'response.output_text.delta','output_index':0,'item_id':item['id'],'content_index':0,'delta':'OSHELL_CLIENT_FIXTURE_PASS'},'response.output_text.delta')
                    send({'type':'response.output_item.done','output_index':0,'item':item},'response.output_item.done')
                    response.update(status='completed',output=[item],usage={'input_tokens':10,'output_tokens':10,'total_tokens':20})
                    send({'type':'response.completed','response':response},'response.completed')
                else:
                    delta={'role':'assistant'}
                    if name:delta['tool_calls']=[{'index':0,'id':callid,'type':'function','function':{'name':name,'arguments':arguments}}]
                    else:delta['content']='OSHELL_CLIENT_FIXTURE_PASS'
                    chunk={'id':'chatcmpl-fixture','object':'chat.completion.chunk','created':int(time.time()),'model':'fixture','choices':[{'index':0,'delta':delta,'finish_reason':None}]};send(chunk)
                    chunk['choices']=[{'index':0,'delta':{},'finish_reason':'tool_calls' if name else 'stop'}];send(chunk);self.wfile.write(b'data: [DONE]\n\n');self.wfile.flush()
                self.close_connection=True
        server=ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
        url='http://127.0.0.1:'+str(server.server_port)+'/v1'
        env=dict(os.environ); env.update(XDG_CONFIG_HOME=str(directory/'config'),XDG_DATA_HOME=str(directory/'data'),XDG_CACHE_HOME=str(directory/'cache'))
        if kind=='codex':
            env['CODEX_HOME']=str(directory/'codex-home');Path(env['CODEX_HOME']).mkdir()
            settings='\n'.join(['model = "fixture"','model_provider = "fixture"','[model_providers.fixture]','name = "fixture"','base_url = '+json.dumps(url),'wire_api = "responses"','requires_openai_auth = false'])+'\n'+(root/'codex-mcp.toml').read_text().replace('[mcp_servers.oshell.env]','default_tools_approval_mode = "approve"\n[mcp_servers.oshell.env]')
            (Path(env['CODEX_HOME'])/'config.toml').write_text(settings)
            command=[executable,'exec','--ephemeral','--skip-git-repo-check','--sandbox','read-only','--json','-c','model_providers.fixture.supports_websockets=false','Use the OShell tools to perform the synthetic fixture task.']
        else:
            config={'$schema':'https://opencode.ai/config.json','model':'fixture/fixture','provider':{'fixture':{'npm':'@ai-sdk/openai-compatible','name':'fixture','options':{'baseURL':url,'apiKey':'synthetic'},'models':{'fixture':{'name':'fixture','limit':{'context':32000,'output':2000}}}}},'mcp':{'oshell':{'type':'local','command':[fixture['helper']],'environment':{'OSHELL_AGENT_SOCKET':fixture['socket'],'OSHELL_AGENT_TOKEN':fixture['token']},'enabled':True}},'permission':{'*':'deny','oshell_*':'allow'}}
            config.update(json.loads((root/'opencode-mcp.json').read_text()))
            (directory/'opencode.json').write_text(json.dumps(config)); env['OPENCODE_CONFIG']=str(directory/'opencode.json');env['OPENCODE_DISABLE_MODELS_FETCH']='true'
            command=[executable,'run','--pure','--format','json','Use the OShell tools for the synthetic fixture task.']
        try:
            process=subprocess.run(command,cwd=directory,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
            (directory/'client.log').write_bytes(process.stdout)
            results[kind+'RealClientFlow']=process.returncode==0 and observed['completed'] and observed['phase']==5
            results[kind+'RealClientToolSchema']=observed['failure'] is None
            (directory/'observed.json').write_text(json.dumps(observed,ensure_ascii=False,indent=2))
        except Exception as error:
            results[kind+'RealClientFlow']=False;(directory/'error.txt').write_text(str(error))
            if getattr(error,'stdout',None):(directory/'client.log').write_bytes(error.stdout)
            (directory/'observed.json').write_text(json.dumps(observed,ensure_ascii=False,indent=2))
        finally:server.shutdown();server.server_close()
    return results
