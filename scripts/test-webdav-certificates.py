#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Real URLSession TLS tests against local synthetic certificates; no system trust changes."""
from xml.sax.saxutils import escape
import datetime,importlib.util,ipaddress,json,os,ssl,tempfile,threading
from pathlib import Path
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from cryptography import x509
from cryptography.hazmat.primitives import hashes,serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID,ExtendedKeyUsageOID
ROOT=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('runner',ROOT/'scripts/run-ui-tests.py');runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)
with tempfile.TemporaryDirectory(prefix='oshell-tls-fixture-') as folder:
 root=Path(folder);servers=[];counts={}
 def certificate(name,expired=False,wrong=False,legacy=False):
  key=rsa.generate_private_key(public_exponent=65537,key_size=2048);now=datetime.datetime.now(datetime.timezone.utc)
  subject=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,name)])
  cert=(x509.CertificateBuilder().subject_name(subject).issuer_name(subject).public_key(key.public_key()).serial_number(x509.random_serial_number())
   .not_valid_before(now-datetime.timedelta(days=30)).not_valid_after(now+datetime.timedelta(days=-1 if expired else 30))
   .add_extension(x509.SubjectAlternativeName([x509.DNSName('wrong.example.test')] if wrong else [x509.DNSName('localhost'),x509.IPAddress(ipaddress.ip_address('127.0.0.1'))]),critical=False)
   .add_extension(x509.BasicConstraints(ca=legacy,path_length=None),critical=True))
  if not legacy: cert=cert.add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]),critical=False)
  cert=cert.sign(key,hashes.SHA256())
  cert_path=root/(name+'.crt');key_path=root/(name+'.key')
  cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM));key_path.touch(mode=0o600)
  key_path.write_bytes(key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
  return str(cert_path),str(key_path)
 valid=certificate('fixture-valid');rotated=certificate('fixture-rotated')
 def server(name,pair,rotate=None):
  counts[name]=0
  class Handler(BaseHTTPRequestHandler):
   def log_message(self,*args): pass
   def reply(self,status,body=b''):
    counts[name]+=1;self.send_response(status);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
   def do_PROPFIND(self):
    self.rfile.read(int(self.headers.get('Content-Length','0')));self.reply(207, ('<d:multistatus xmlns:d="DAV:"><d:response><d:href>'+escape(self.path)+'</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>').encode())
    if rotate and self.path.startswith('/rotate/'):
     context.load_cert_chain(*rotate)
   def do_GET(self):
    if self.path.startswith('/redirect/'):
     self.send_response(302);self.send_header('Location',f'http://127.0.0.1:{self.server.server_port}/downgrade/');self.send_header('Content-Length','0');self.end_headers()
    else: self.reply(404)
  instance=ThreadingHTTPServer(('127.0.0.1',0),Handler)
  context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(*pair)
  instance.socket=context.wrap_socket(instance.socket,server_side=True)
  threading.Thread(target=instance.serve_forever,daemon=True).start();servers.append(instance)
  return f'https://127.0.0.1:{instance.server_port}/'
 try:
  base=server('valid',valid,rotated)
  fixture={'valid':base+'dav/','rotate':base+'rotate/','otherPort':server('other',valid)+'dav/',
           'expired':server('expired',certificate('fixture-expired',expired=True))+'dav/',
           'wrongHost':server('wrong',certificate('fixture-wrong',wrong=True))+'dav/',
           'legacyEKU':server('legacy',certificate('fixture-legacy',legacy=True))+'dav/'}
  fixture['wrongDNS']=fixture['wrongHost'].replace('127.0.0.1','localhost')
  path=root/'urls.json';path.write_text(json.dumps(fixture));os.environ['OSHELL_DAV_TLS_FIXTURE']=str(path)
  # open --env only passes explicitly named keys; add this fixture key without
  # ever passing or copying server private keys to the test app.
  runner.CASES['webdav-certificate']='OSHELL_CERTIFICATE_OUTPUT'
  original=runner.subprocess.run
  def run(command,*args,**kwargs):
   if isinstance(command,list) and command and command[0]=='open':
    command=command.copy();command[1:1]=['--env','OSHELL_DAV_TLS_FIXTURE='+str(path)]
   return original(command,*args,**kwargs)
  runner.subprocess.run=run
  runner.run_case(ROOT/'work/test-app/OShell.app','webdav-certificate',180)
  assert counts['other']==counts['expired']==0,'Rejected TLS endpoints received an HTTP request'
  assert counts['legacy']>0 and counts['wrong']>0,'Explicit IP certificate trust did not connect'
  print('PASS: scoped trust, certificate change, IP name/EKU exceptions only after confirmation, expiry/DNS rejection, no credential-bearing HTTP before trust; no system trust modified')
 finally:
  for instance in servers: instance.shutdown();instance.server_close()
