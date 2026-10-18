#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Audit publishable content without printing matched secrets or private values."""
import argparse,json,os,pathlib,posixpath,re,subprocess,sys
ROOT=pathlib.Path(__file__).resolve().parent.parent
RULES={
 'personal-home-path':re.compile(rb'(?:/Users|/home)/[A-Za-z0-9_.-]+/'),
 'windows-home-path':re.compile(rb'(?i)[a-z]:(?:\\+|/)(?:Users|Documents and Settings)(?:\\+|/)[^\\/\r\n\x00]+'),
 'workstation-temp-path':re.compile(rb'(?:/private)?/var/folders/[A-Za-z0-9]{2}/[A-Za-z0-9_-]{12,}/'),
 'private-key-material':re.compile(rb'-----BEGIN (?:ENCRYPTED |OPENSSH |RSA |EC |DSA )?PRIVATE KEY-----'),
 'github-token':re.compile(rb'(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})'),
 'cloud-access-key':re.compile(rb'AKIA[A-Z0-9]{16}')}
# Explicit public update coordinates requested by the repository owner. Only
# quoted coordinates and these HTTPS endpoints are exempt from the workstation
# name check; personal paths, tokens and explicit private patterns still apply.
PUBLIC_UPDATE_REPOSITORIES = (b"arnolixi/oshell", b"arnolixi/arnolixi.github.io")
PUBLIC_UPDATE_URLS = tuple(b"https://github.com/" + repo for repo in PUBLIC_UPDATE_REPOSITORIES) + (b"https://arnolixi.github.io/oshell",)
PUBLIC_COORDINATE = re.compile(rb"(['\"`])(?:" + b"|".join(map(re.escape, PUBLIC_UPDATE_REPOSITORIES)) + rb")\1")
PUBLIC_URL = re.compile(rb"(?:" + b"|".join(map(re.escape, PUBLIC_UPDATE_URLS)) + rb")(?=$|[/ ?#'\"`<>\r\n])")
def without_public_update_coordinates(data):
 return PUBLIC_URL.sub(b'<public-update-url>', PUBLIC_COORDINATE.sub(b'<public-update-repository>', data))

def git(*args):return subprocess.check_output(['git','-C',str(ROOT),*args])
def forbidden(path):
 p=pathlib.PurePosixPath(path)
 return (p.parts[0] in ['work','dist','.release-private','.build','.swiftpm','.codex','.agents','.idea','.vscode'] or
         (p.parts[0]=='validation' and path!='validation/.gitkeep') or
         p.name in ['PROJECT_STATE.md','VALIDATION.md','configuration.json','local-credential-key.json','known_hosts','.DS_Store','.netrc','.npmrc','id_rsa','id_dsa','id_ecdsa','id_ed25519'] or
         ((p.name.startswith('.env') or p.name.endswith('.env') or '.env.' in p.name) and not p.name.endswith('.env.example') and p.name!='.env.example') or
         p.name.endswith('.oshell.json') or p.suffix.lower() in ['.xsh','.xts','.xfp'] or '.ssh' in p.parts or '.aws' in p.parts or
         ('xcuserdata' in p.parts or '__pycache__' in p.parts) or p.suffix.lower() in ['.key','.pem','.p12','.pfx','.log','.pyc','.xcuserstate','.code-workspace'] or
         any(x.endswith('.dSYM') for x in p.parts))
def audit(path,data,private_patterns,app=False):
 findings=[]
 if not app and forbidden(path):findings.append('excluded-local-file')
 # Wide-character strings occur in Windows exports and some binary metadata.
 views=[data]
 if b'\0' in data:views.append(data.replace(b'\0',b''))
 if not app and not path.startswith('Vendor/'):
  findings.extend(name for name,rule in RULES.items() if any(rule.search(view) for view in views))
  suffix=pathlib.PurePosixPath(path).suffix.lower()
  if suffix=='.json':
   try:
    value=json.loads(data)
    if isinstance(value,dict) and (value.get('format')=='OShell.sessions' or ('profiles' in value and 'preferences' in value)):findings.append('session-configuration')
   except (ValueError,UnicodeError):pass
  if suffix=='.xml' and any(re.search(rb'<VanDyke(?:\s|>)',view,re.I) for view in views):findings.append('external-session-export')
  if suffix=='.ini' and any(re.search(rb'(?m)^\s*S:"(?:Hostname|Protocol Name)"=',view) for view in views):findings.append('external-session-export')
 else:
  # Preserve public upstream attribution; detect this workstation in vendor/app bytes.
  if any(str(pathlib.Path.home()).encode() in view or str(ROOT).encode() in view for view in views):findings.append('current-workstation-path')
 local_user=pathlib.Path.home().name
 if local_user.lower() not in ['root','runner','user','admin','administrator','build','builder','nobody']:
  identity=re.compile(rb'(?i)(?<![a-z0-9])'+re.escape(local_user.encode())+rb'(?![a-z0-9])')
  if any(identity.search(view) for view in [without_public_update_coordinates(v) for v in views]+[path.encode()]):findings.append('current-workstation-identity')
 for pattern in private_patterns:
  value=pattern.casefold().encode()
  if not value:continue
  expression=(rb'(?<![a-z0-9])' if re.match(rb'[a-z0-9]',value) else b'')+re.escape(value)+(rb'(?![a-z0-9])' if re.search(rb'[a-z0-9]$',value) else b'')
  if any(re.search(expression,view.lower()) for view in views+[path.encode()]):findings.append('private-pattern')
 return sorted(set(findings))
def blobs(entries):
 process=subprocess.Popen(['git','-C',str(ROOT),'cat-file','--batch'],stdin=subprocess.PIPE,stdout=subprocess.PIPE)
 try:
  for path,oid,mode in entries:
   process.stdin.write(oid.encode()+b'\n');process.stdin.flush()
   header=process.stdout.readline().split()
   if len(header)!=3 or header[1]!=b'blob':raise RuntimeError('Cannot read indexed blob')
   size=int(header[2]);data=process.stdout.read(size);process.stdout.read(1)
   yield path,data,mode
 finally:
  process.stdin.close();process.wait()
def inspect(args):
 private_patterns=[]
 if args.private_patterns:private_patterns=json.loads(args.private_patterns.read_text())
 findings=[];count=0
 if args.app:
  entries=((str(p.relative_to(args.app)),os.readlink(p).encode() if p.is_symlink() else p.read_bytes(),'120000' if p.is_symlink() else '100644') for p in args.app.rglob('*') if p.is_file() or p.is_symlink())
 elif args.history:
  ref=git('rev-parse','--verify',args.history+'^{commit}').decode().strip() if args.history!='ALL' else None
  commits=git('rev-list',*(['--all'] if ref is None else [ref])).decode().split()
  unique={}
  for commit in commits:
   # Author/committer identities are intentionally retained. Commit messages can
   # still accidentally contain workstation paths or credentials.
   message=git('show','-s','--format=%B',commit)
   rules=audit('commit-message',message,private_patterns)
   if rules:findings.append({'path':'commit:'+commit[:12]+':message','rules':rules})
   for row in git('ls-tree','-r','-z',commit).split(b'\0'):
    if not row:continue
    meta,name=row.split(b'\t',1);mode,kind,oid=meta.split()
    if kind==b'blob':unique[(name.decode(),oid.decode(),mode.decode())]=None
  entries=blobs(unique.keys())
 elif args.working_tree:
  names=set(git('ls-files','--cached','--others','--exclude-standard','-z').decode().split('\0'))
  entries=((name,os.readlink(ROOT/name).encode() if (ROOT/name).is_symlink() else (ROOT/name).read_bytes(),'120000' if (ROOT/name).is_symlink() else '100644') for name in sorted(names) if name and ((ROOT/name).is_file() or (ROOT/name).is_symlink()))
 else:
  indexed=[]
  for row in git('ls-files','--stage','-z').split(b'\0'):
   if not row:continue
   meta,name=row.split(b'\t',1);mode,oid,stage=meta.split()
   if stage!=b'0':raise RuntimeError('Resolve merge conflicts before publication')
   if mode==b'160000':findings.append({'path':name.decode(),'rules':['unresolved-embedded-repository']});continue
   indexed.append((name.decode(),oid.decode(),mode.decode()))
  entries=blobs(indexed)
 for path,data,mode in entries:
  count+=1;rules=audit(path,data,private_patterns,app=bool(args.app))
  if mode=='120000':
   target=data.decode(errors='replace');resolved=posixpath.normpath(posixpath.join(posixpath.dirname(path),target))
   if target.startswith('/') or resolved=='..' or resolved.startswith('../') or (not args.app and forbidden(resolved)):rules.append('unsafe-symlink')
  if rules:findings.append({'path':path,'rules':rules})
 return {'passed':not findings,'filesChecked':count,'findings':findings}
def main():
 parser=argparse.ArgumentParser(description=__doc__)
 modes=parser.add_mutually_exclusive_group();modes.add_argument('--working-tree',action='store_true');modes.add_argument('--index',action='store_true');modes.add_argument('--history',metavar='REF');modes.add_argument('--app',type=pathlib.Path)
 parser.add_argument('--private-patterns',type=pathlib.Path,help='Local ignored JSON array of additional private strings; values are never printed')
 parser.add_argument('--output',type=pathlib.Path)
 args=parser.parse_args();report=inspect(args);encoded=json.dumps(report,ensure_ascii=False,indent=2)
 if args.output:args.output.write_text(encoded+'\n')
 print(encoded);return 0 if report['passed'] else 1
if __name__=='__main__':sys.exit(main())
