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
    source=root/'stage4/OShell.app'; app(source,'helper-only upgrade')
    helper=target/'Contents/Helpers/OShell-MCP'; helper.parent.mkdir(); helper.write_text('old helper')
    with helper.open() as mapped_helper:
        assert module.publish(source,target,[str(helper)]) == target
        assert mapped_helper.read() == 'old helper'
    assert old.read_text() == 'helper-only upgrade'
    source=root/'stage5/OShell.app'; app(source,'other helper running')
    assert module.publish(source,target,[str(helper)+'-other']) != target
    source=root/'stage6/OShell.app'; app(source,'helper rollback')
    try:
        with patch.object(module.os,'rename',fail): module.publish(source,target,[str(helper)])
    except OSError: pass
    else: raise AssertionError('expected helper-only rollback')
    assert old.read_text() == 'helper-only upgrade' and source.exists()
print('local app publication: app/other helpers preserved, MCP-only upgrade, inode safety and rollback passed')
