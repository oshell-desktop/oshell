#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Focused real STDIO/PTY checks for text views, approval waits and lightweight state."""
import base64, importlib.util, json, shlex, time, uuid
from pathlib import Path

spec = importlib.util.spec_from_file_location('agent_protocol_support', Path(__file__).with_name('test-agent-protocol.py'))
p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
c = p.Client(); check, action, config = p.check, p.action, p.config

def quick(command, **extra):
    return c.tool('session_exec', session_id=config['pane'], generation=config['generation'], command=command, idempotency_key=str(uuid.uuid4()), **extra)

def send_read(op, **extra):
    c.counter += 1; request = c.counter
    c.send(dict(jsonrpc='2.0', id=request, method='tools/call', params=dict(name='operation_read', arguments=dict(operation_id=op, format='compact', **extra))))
    return request

def response(request):
    result = c.response(request)['result']
    return {'error': result['content'][0]['text']} if result.get('isError') else json.loads(result['content'][0]['text'])

try:
    p.ready(c)
    old = c.tool('session_state', session_id=config['pane'])
    light = c.tool('session_state', session_id=config['pane'], include_screen=False)
    check('lightStateOmitsOnlyScreen', 'screen' in old and 'screen' not in light and {k:v for k,v in old.items() if k!='screen'} == light)
    check('invalidScreenFlagRejected', 'error' in c.tool('session_state', session_id=config['pane'], include_screen='no'))
    check('lightStateStillChecksAuthorization', 'error' in c.tool('session_state', session_id=config['hidden'], include_screen=False))
    check('invalidTextOptionsDoNotExecute', 'error' in quick('pwd', view='text', tail_lines=0) and not c.tool('session_state',session_id=config['pane'],include_screen=False)['task_active'])
    check('queryRequiresTextView', 'error' in quick('pwd', contains='x'))
    check('shortcutForwardsTextView', quick('pwd',view='text',wait_ms=3000).get('body_ended') is True)

    q = quick("printf '\\033[31m中文🙂\\033[0m\\nERROR one\\nnormal\\nERROR two\\n'", view='text')
    op = q['operation']['operation_id']
    check('textPendingDoesNotLeakCommandEcho', q['output_text']=='' and q['next_action']=='approve_in_oshell')
    before = time.monotonic()
    timed = c.tool('operation_read',operation_id=op,wait_for='approval',wait_ms=120,format='compact')
    check('approvalTimeoutKeepsPendingCommand', time.monotonic()-before>=.08 and timed['operation']['state']=='pending_approval')
    request = send_read(op, wait_for='approval', wait_ms=5000)
    check('approvalWaitDoesNotBlockStatus', not c.tool('session_state',session_id=config['pane'],include_screen=False)['can_exec'])
    action('approve', operation=op)
    approved = response(request)
    check('approvalWaitResumesWithoutChatReply', approved['operation']['state']!='pending_approval' and approved['operation']['operation_id']==op)
    result = c.tool('operation_read',operation_id=op,view='text',wait_for='completion',wait_ms=3000)
    expected = '中文🙂\nERROR one\nnormal\nERROR two\n'
    if result.get('output_text') != expected or not result.get('completed'):
        print('TEXT_RESULT',repr(result),flush=True)
        print('RAW_RESULT',repr(base64.b64decode(c.tool('operation_read',operation_id=op)['output_base64'])),flush=True)
    check('textViewContainsOnlyCommandBody', result['completed'] and result['output_text']==expected and result['body_started'] and result['body_ended'])
    tail = c.tool('operation_read',operation_id=op,view='text',tail_lines=1,contains='ERROR')
    check('tailKeywordQuery', tail['output_text']=='ERROR two\n' and tail['truncated'] and not tail['has_more'])
    no_match = c.tool('operation_read',operation_id=op,view='text',contains='not present')
    check('noMatchAdvancesCursorAndCompletes', no_match['output_text']=='' and no_match['next_cursor']>0 and no_match['completed'])
    legacy = c.tool('operation_read',operation_id=op)
    check('legacyReadUnchanged', set(legacy)=={'operation','stream','next_cursor','durable_sequence','output_base64','output_text'} and b'\x1b[31m' in base64.b64decode(legacy['output_base64']))
    cursor, pieces = 0, b''
    while True:
        part = c.tool('operation_read',operation_id=op,view='text',cursor=cursor,limit=7)
        pieces += part['output_text'].encode() if part['encoding']=='utf8' else base64.b64decode(part['output_base64'])
        check('textCursorAlwaysAdvancesOrEnds', part['next_cursor']>cursor or not part['has_more'])
        cursor = part['next_cursor']
        if not part['has_more']: break
    check('textPaginationPreservesUTF8AndRawCursor', pieces.decode()==expected and cursor==legacy['next_cursor'])
    check('invalidTextCursorDoesNotBreakAudit', 'error' in c.tool('operation_read',operation_id=op,view='text',cursor=99999999) and c.tool('session_state',session_id=config['pane'],include_screen=False)['audit_error'] is None)

    q = quick('/usr/bin/python3 -c '+shlex.quote('print("row-data-12345\\n"*100000+"FINAL 中文")'));op=q['operation']['operation_id']
    action('approve',operation=op)
    c.tool('operation_read',operation_id=op,wait_for='completion',wait_ms=10000,format='compact',limit=1)
    first = c.tool('operation_read',operation_id=op,view='text',tail_lines=1)
    check('tailScanWorkIsBounded', first['has_more'] and first['next_cursor']<=1048576 and first['window_bytes']==131072)
    last = c.tool('operation_read',operation_id=op,view='text',tail_lines=1,cursor=first['next_cursor'])
    check('tailContinuationFindsLatestLine', not last['has_more'] and last['output_text']=='FINAL 中文\n' and last['truncated'])

    q = quick("printf DENIED_MUST_NOT_EXECUTE"); op=q['operation']['operation_id']
    request = send_read(op,wait_for='approval',wait_ms=5000)
    action('deny',operation=op)
    check('denialWakesApprovalWait', response(request)['operation']['state']=='denied')
    q = quick("printf CANCEL_WAIT_ONLY");op=q['operation']['operation_id']
    request = send_read(op,wait_for='approval',wait_ms=10000)
    time.sleep(.1)
    c.send(dict(jsonrpc='2.0',method='notifications/cancelled',params=dict(requestId=request,reason='fixture')))
    check('approvalWaitCancellationReturns', 'error' in response(request))
    check('cancelledWaitDoesNotApproveOrRun', c.tool('operation_read',operation_id=op,format='compact')['operation']['state']=='pending_approval')
    action('deny',operation=op)
    q = quick("printf REVOKED_MUST_NOT_EXECUTE");op=q['operation']['operation_id']
    request = send_read(op,wait_for='approval',wait_ms=5000)
    action('takeover')
    check('revocationWakesApprovalWaitWithoutOutput', 'error' in response(request))
    check('revokedLightStateDenied', 'error' in c.tool('session_state',session_id=config['pane'],include_screen=False))
finally:
    c.close()
    (p.root/'checks.json').write_text(json.dumps(p.checks,ensure_ascii=False,indent=2))
print('PASS',len(p.checks),'focused reading checks')
