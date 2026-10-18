#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Exercise index/history privacy checks using synthetic, disposable Git content."""
import argparse,importlib.util,pathlib,subprocess,tempfile
from unittest.mock import patch
ROOT=pathlib.Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('audit',ROOT/'scripts/check-public-source.py');audit=importlib.util.module_from_spec(spec);spec.loader.exec_module(audit)
with tempfile.TemporaryDirectory(prefix='oshell-public-check-') as folder:
 root=pathlib.Path(folder);audit.ROOT=root
 def git(*args):subprocess.run(['git','-C',str(root),*args],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 def report(history=None,app=None):return audit.inspect(argparse.Namespace(private_patterns=None,app=app,history=history,working_tree=False,index=True))
 git('init','-b','main');git('config','user.name','Fixture');git('config','user.email','fixture@example.test')
 (root/'README.md').write_text('Public project\n');git('add','README.md');assert report()['passed']
 git('commit','-m','fixture baseline')
 (root/'.env').write_text('not a real credential');git('add','.env');assert not report()['passed']
 git('rm','--cached','.env');(root/'.env').unlink()
 (root/'README.md').write_text('/Us'+'ers/private-fixture/project/file.swift');git('add','README.md');assert not report()['passed']
 git('commit','-m','synthetic path fixture')
 (root/'README.md').write_text('Public project\n');git('add','README.md');git('commit','-m','remove fixture')
 assert report()['passed'] and not report(history='main')['passed']
 (root/'token.txt').write_text('gh'+'p_'+'x'*36);git('add','token.txt');assert not report()['passed'];git('rm','-f','token.txt')
 (root/'link').symlink_to('../outside.key');git('add','link');assert not report()['passed'];git('rm','-f','link')
 (root/'link').symlink_to('README.md');git('add','link');assert report()['passed']
 app=root/'Fixture.app';app.mkdir();binary=app/'fixture';binary.write_bytes(b'\0'+str(pathlib.Path.home()).encode()+b'/private-file');assert not report(app=app)['passed']
 # New import formats must not accidentally become source-control data.
 for name,body in [('sessions.xsh','[CONNECTION]'),('sessions.xts','fixture'),('sessions.xfp','fixture'),('sessions.ini','S:"Hostname"=example.test'),('export.xml','<VanDyke><key name="Sessions"/></VanDyke>'),('renamed.json','{"format":"OShell.sessions","profiles":[]}')]:
  (root/name).write_text(body);git('add',name);assert not report()['passed'];git('rm','-f',name)
 windows='C:'+chr(92)+'Users'+chr(92)+'fixture-private'+chr(92)+'document.txt'
 (root/'wide.txt').write_bytes(windows.encode('utf-16le'));git('add','wide.txt');assert not report()['passed'];git('rm','-f','wide.txt')
 git('commit','--allow-empty','-m','fixture message '+('/Us'+'ers/private-fixture/notes'))
 assert not report(history='main')['passed']
 patterns=root/'private-patterns.json';patterns.write_text('["fixture-person", "private-fixture-id"]')
 args=argparse.Namespace(private_patterns=patterns,app=None,history=None,working_tree=False,index=True)
 (root/'safe.txt').write_text('public fixture');git('add','safe.txt');assert audit.inspect(args)['passed']
 (root/'safe.txt').write_text('FIXTURE-PERSON');git('add','safe.txt');assert not audit.inspect(args)['passed'];git('rm','-f','safe.txt')
 (root/'fixture-person.txt').write_text('public fixture');git('add','fixture-person.txt');assert not audit.inspect(args)['passed'];git('rm','-f','fixture-person.txt')
print('PASS: clean index, excluded file, personal path, historical leak, token, unsafe/safe symlinks, binary build path, external exports, Windows/UTF-16 paths, commit messages and private identifiers')

# Allow only the public update identifiers; never a bare username, home path,
# unrelated repository, personal filename or caller-supplied private pattern.
owner=audit.PUBLIC_UPDATE_REPOSITORIES[0].split(b'/')[0]
with patch.object(audit.pathlib.Path,'home',return_value=pathlib.Path('/Users')/owner.decode()):
 for data in [b'`'+audit.PUBLIC_UPDATE_REPOSITORIES[0]+b'`',b"'"+audit.PUBLIC_UPDATE_REPOSITORIES[1]+b"'",audit.PUBLIC_UPDATE_URLS[-1]+b'/updates/latest.json']:
  assert not audit.audit('public.md',data,[])
 for data in [owner,b'/Users/'+owner+b'/oshell/config',b'https://example.test/'+owner,b"'"+owner+b"/private-repository'"]:
  assert audit.audit('private.md',data,[])
 assert audit.audit(owner.decode()+'.txt',b'public',[])
 assert 'private-pattern' in audit.audit('public.md',audit.PUBLIC_UPDATE_URLS[-1],[owner.decode()])
print('PASS: exact public update addresses allowed; other workstation identities remain rejected')
