#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Loopback-only mixed proxy chains with ephemeral SSH keys and fictional credentials."""
import argparse, base64, collections, json, os, select, signal, socket, struct, subprocess, tempfile, threading, uuid
from pathlib import Path
import paramiko
ROOT=Path(__file__).resolve().parents[1]
def exact(s,n):
 data=b''
 while len(data)<n:
  chunk=s.recv(n-len(data))
  if not chunk: raise EOFError()
  data+=chunk
 return data
def bridge(a,b):
 try:
  readers=[a,b]
  while readers:
   readable,_,_=select.select(readers,[],[],15)
   if not readable: break
   for x in readable:
    data=x.recv(32768);other=b if x is a else a
    if data:other.sendall(data)
    else:
     readers.remove(x)
     if isinstance(other,paramiko.Channel):other.shutdown_write()
     else:other.shutdown(socket.SHUT_WR)
 finally:a.close();b.close()

def listen(handler):
 s=socket.socket();s.bind(('127.0.0.1',0));s.listen(20)
 def serve():
  while True:
   try:c,_=s.accept()
   except OSError:return
   threading.Thread(target=lambda c=c: safe(handler,c),daemon=True).start()
 threading.Thread(target=serve,daemon=True).start();return s
def safe(handler,c):
 try:handler(c)
 except Exception:c.close()
def main():
 parser=argparse.ArgumentParser();parser.add_argument('--flavor',choices=['arm64','amd64'],default='arm64');args=parser.parse_args()
 app=ROOT/('work/test-app/OShell.app' if args.flavor=='arm64' else 'work/test-release/amd64/OShell.app')
 binary_dir=Path(subprocess.check_output(['swift','build','--scratch-path',str(ROOT/'work/build-tests/swift'),'-c','release','--show-bin-path'],text=True).strip())
 resolver=binary_dir/'OShellCoreChecks'
 helper=app/'Contents/Helpers/OShellProxy';askpass=app/'Contents/Helpers/OShellAskpass'
 with tempfile.TemporaryDirectory(prefix='oshell-proxy-chain-',dir='/tmp') as raw:
  root=Path(raw);hostkey=paramiko.RSAKey.generate(2048);clientkey=paramiko.RSAKey.generate(2048)
  key=root/'private key';clientkey.write_private_key_file(str(key));key.chmod(0o600)
  facts={'password':0,'key':0,'socks':0,'http':0,'socks4':0,'socks4a':0};listeners=[]
  def echo(c):
   while True:
    data=c.recv(32768)
    if not data:break
    c.sendall(data)
   c.close()
  target=listen(echo);listeners.append(target)
  class SSH(paramiko.ServerInterface):
   def __init__(self,mode):self.mode=mode;self.destinations={}
   def get_allowed_auths(self,user):return 'password' if self.mode=='password' else 'publickey'
   def check_auth_password(self,user,password):
    if self.mode=='password' and user=='jump-user' and password=='jump-fixture-password':facts['password']+=1;return paramiko.AUTH_SUCCESSFUL
    return paramiko.AUTH_FAILED
   def check_auth_publickey(self,user,key):
    if self.mode=='key' and user=='jump-user' and key==clientkey:facts['key']+=1;return paramiko.AUTH_SUCCESSFUL
    return paramiko.AUTH_FAILED
   def check_channel_direct_tcpip_request(self,channel,origin,destination):
    if destination[0]!='127.0.0.1':return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
    self.destinations[channel]=destination;return paramiko.OPEN_SUCCEEDED
  def ssh(c,mode):
   t=paramiko.Transport(c);t.add_server_key(hostkey);server=SSH(mode)
   try:
    t.start_server(server=server)
    while t.is_active():
     channel=t.accept(2)
     if channel is not None:
      dest=server.destinations[channel.get_id()];remote=socket.create_connection(dest,timeout=10)
      threading.Thread(target=bridge,args=(channel,remote),daemon=True).start()
   finally:t.close()
  for mode in ['password','key']:listeners.append(listen(lambda c,mode=mode:ssh(c,mode)))
  def socks(c):
   version,count=exact(c,2);methods=exact(c,count);assert version==5 and 2 in methods;c.sendall(b'\x05\x02')
   assert exact(c,1)==b'\x01';user=exact(c,exact(c,1)[0]);password=exact(c,exact(c,1)[0]);assert user==b'proxy-user' and password==b'socks-fixture-password';facts['socks']+=1;c.sendall(b'\x01\x00')
   v,cmd,_,kind=exact(c,4);assert v==5 and cmd==1
   host=socket.inet_ntoa(exact(c,4)) if kind==1 else exact(c,exact(c,1)[0]).decode();port=struct.unpack('!H',exact(c,2))[0]
   remote=socket.create_connection((host,port),timeout=10);c.sendall(b'\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00');bridge(c,remote)
  def http(c):
   data=b''
   while not data.endswith(b'\r\n\r\n'):data+=exact(c,1)
   assert b'Proxy-Authorization: Basic '+base64.b64encode(b'proxy-user:http-fixture-password') in data;facts['http']+=1
   host,port=data.split(b' ')[1].decode().rsplit(':',1);remote=socket.create_connection((host.strip('[]'),int(port)),timeout=10)
   c.sendall(b'HTTP/1.1 200 Connection established\r\n\r\n');bridge(c,remote)
  listeners+=[listen(socks),listen(http)]
  def socks4(c):
   version,command,port,address=struct.unpack('!BBH4s',exact(c,8));assert version==4 and command==1
   def terminated():
    value=b''
    while True:
     byte=exact(c,1)
     if byte==b'\0':return value
     value+=byte
   terminated()
   v4a=address[:3]==b'\0\0\0' and address[3]!=0
   host=terminated().decode() if v4a else socket.inet_ntoa(address)
   assert host=='127.0.0.1';facts['socks4a' if v4a else 'socks4']+=1
   remote=socket.create_connection((host,port),timeout=10)
   c.sendall(b'\x00\x5a'+struct.pack('!H',port)+socket.inet_aton('127.0.0.1'));bridge(c,remote)
  listeners += [listen(socks4),listen(socks4)]
  known=root/'known_hosts';known.write_text(''.join(f'[127.0.0.1]:{s.getsockname()[1]} {hostkey.get_name()} {hostkey.get_base64()}\n' for s in listeners[1:3]))
  nodes={}
  for label,index,kind,mode in [('ssh-password',1,'jump','password'),('ssh-key',2,'jump','privateKey'),('socks',3,'socks5','automatic'),('http',4,'http','automatic'),('socks4',5,'socks4','automatic'),('socks4a',6,'socks4a','automatic')]:
   nodes[label]=dict(id=str(uuid.uuid4()).upper(),kind=kind,host='127.0.0.1',port=listeners[index].getsockname()[1],username='jump-user' if kind=='jump' else 'proxy-user',identityFile=str(key) if mode=='privateKey' else '',sshAuthentication=mode)
  auth=root/'a';server=socket.socket(socket.AF_UNIX);server.bind(str(auth));os.chmod(auth,0o600);server.listen(20)
  state={'route':[],'token':str(uuid.uuid4()),'requests':[]}
  def authenticate(c):
   request=json.loads(exact(c,struct.unpack('!I',exact(c,4))[0]));assert request['token']==state['token'];hint=request['hint']
   if hint=='oshell-proxy-route':answer=json.dumps(state['route']);ok=True
   else:
    ident=request.get('proxyID');state['requests'].append((ident,hint))
    label=next((label for label,node in nodes.items() if node['id']==ident),'')
    answer={'ssh-password':'jump-fixture-password','socks':'socks-fixture-password','http':'http-fixture-password'}.get(label,'');ok=bool(answer)
   data=json.dumps(dict(success=ok,answer=answer)).encode();c.sendall(struct.pack('!I',len(data))+data);c.close()
  def accept():
   while True:
    try:c,_=server.accept()
    except OSError:return
    threading.Thread(target=lambda c=c:safe(authenticate,c),daemon=True).start()
  threading.Thread(target=accept,daemon=True).start()
  checks={}
  try:
   kinds=['socks4','socks4a','socks','http','ssh-password','ssh-key']
   cases=[([kind],[]) for kind in kinds]
   cases += [([first],[second]) for first in kinds for second in kinds if first!=second]
   cases += [([first],['ssh-password','ssh-key']) for first in ['socks4','socks4a','socks','http']]
   cases += [(['socks','ssh-password'],['http','ssh-key'])]
   for global_chain,session_chain in cases:
    fixture=root/'route.json'
    fixture.write_text(json.dumps({'global':[nodes[n] for n in global_chain],'session':[nodes[n] for n in session_chain]}))
    state['route']=json.loads(subprocess.check_output([str(resolver),'--global-proxy-fixture',str(fixture)]));state['requests']=[]
    chain=global_chain+session_chain
    assert [hop['id'] for hop in state['route']]==[nodes[n]['id'] for n in chain]
    env=dict(os.environ,OSHELL_AUTH_SOCKET=str(auth),OSHELL_AUTH_TOKEN=state['token'],SSH_ASKPASS=str(askpass),SSH_ASKPASS_REQUIRE='force',DISPLAY='oshell:0')
    payload=b'OSHELL-PROXY-FIXTURE\n'*16
    before=facts.copy()
    process=subprocess.Popen([str(helper),'--route-index',str(len(chain)-1),'--target-host','127.0.0.1','--target-port',str(target.getsockname()[1]),'--known-hosts',str(known),'--tcp-keepalive','yes'],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
    try:out,err=process.communicate(payload,timeout=30)
    except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);out,err=process.communicate();checks['timeout-'+str(chain)]=False
    label=' -> '.join(chain);checks[label]=out==payload and process.returncode==0
    expected=collections.Counter({'password' if item=='ssh-password' else 'key' if item=='ssh-key' else item:chain.count(item) for item in chain})
    checks[label+' all-hops-used']=all(facts[name]-before[name]==expected[name] for name in facts)
    checks[label+' credential-scope']=all(ident in {nodes[n]['id'] for n in chain} for ident,hint in state['requests'])
    if not checks[label]:(ROOT/'validation/proxy-chain-error.log').write_bytes(err)
   checks['all-authentication-types-used']=all(facts.values())
   result=dict(passed=all(checks.values()),checks=checks)
   (ROOT/f'validation/proxy-chain-{args.flavor}.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
   return 0 if result['passed'] else 1
  finally:
   server.close()
   for s in listeners:s.close()
if __name__=='__main__':raise SystemExit(main())
