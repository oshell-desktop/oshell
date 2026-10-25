#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
import importlib.util
from pathlib import Path
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('installer', Path(__file__).with_name('install-local-app.py'))
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)

def app(path, text):
    executable = path / 'Contents/MacOS/OShell'
    executable.parent.mkdir(parents=True); executable.write_text(text)
    return executable

with tempfile.TemporaryDirectory() as raw:
    root=Path(raw); target=root/'OShell.app'
    old=app(target, 'old'); inode=old.stat().st_ino
    source=root/'stage1/OShell.app'; app(source,'new')
    result=module.publish(source,target,[str(old)])
    assert result != target and old.read_text() == 'old' and old.stat().st_ino == inode
    assert (result/'Contents/MacOS/OShell').read_text() == 'new'
    source=root/'stage2/OShell.app'; app(source,'replacement')
    with old.open() as running_image:
        assert module.publish(source,target,[]) == target
        assert running_image.read() == 'old'  # mapped/open file never overwritten
    assert old.read_text() == 'replacement'
    source=root/'stage3/OShell.app'; app(source,'failed')
    rename=module.os.rename
    def fail(source_path,dest):
        if Path(source_path).resolve() == source.resolve(): raise OSError('synthetic publish failure')
        rename(source_path,dest)
    try:
        with patch.object(module.os,'rename',fail): module.publish(source,target,[])
    except OSError: pass
    else: raise AssertionError('expected failure')
    assert old.read_text() == 'replacement' and source.exists()
print('local app publication: running app preserved, no inode truncation, rollback passed')
