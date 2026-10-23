#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Isolated native AI workflow with a loopback-only synthetic model server."""
import base64, hashlib, importlib.util, json, threading, time
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
captures = []
native_checks = {}
native_errors = []
provider_checks = {}
facts = {'requests': 0, 'slowRequests': 0, 'sinkRequests': 0, 'redacted': True, 'authCorrect': True, 'images': False, 'boundedOutput': True}

def inspect_native(kind, action, payload, headers, path):
    # Assertions are independent of the Swift serializer, on bytes received over HTTP.
    assert '?' not in path and '{' not in path
    assert not any(k in payload for k in ['previous_response_id', 'conversation', 'tools', 'cachedContent', 'continuationToken'])
    auth = 'x-api-key' if kind == 'anthropic' else 'x-goog-api-key' if kind == 'gemini' else 'Authorization'
    assert headers.get(auth) == ('Bearer ' if auth == 'Authorization' else '') + 'synthetic-ai-key'
    assert all(headers.get(h) is None for h in ['x-api-key', 'x-goog-api-key', 'Authorization'] if h != auth)
    if kind == 'anthropic': assert headers.get('anthropic-version') == '2023-06-01'
    else: assert headers.get('anthropic-version') is None
    if kind in ['chatCompletions', 'responses']: assert payload['store'] is False and payload['stream'] is False
    if kind == 'chatCompletions':
        assert payload['model'] == 'native-model' and payload['max_completion_tokens'] == 4096
        messages = payload['messages']; assert messages[0]['role'] == 'system'
        messages = messages[1:]
    elif kind == 'responses':
        assert payload['model'] == 'native-model' and payload['max_output_tokens'] == 4096
        assert isinstance(payload['instructions'], str) and payload['instructions']
        assert 'messages' not in payload
        messages = payload['input']
    elif kind == 'anthropic':
        assert payload['model'] == 'native-model' and payload['max_tokens'] == 4096 and payload['stream'] is False
        assert isinstance(payload['system'], str) and payload['system']
        messages = payload['messages']
    else:
        assert path.endswith('/models/native-model:generateContent') and 'model' not in payload
        assert payload['generationConfig'] == {'maxOutputTokens': 4096, 'candidateCount': 1}
        assert payload['systemInstruction']['parts'][0]['text'] and payload['store'] is False
        messages = payload['contents']
    all_text, images, roles = [], [], []
    for message in messages:
        role = message['role']; roles.append(role)
        assert role in (['user', 'model'] if kind == 'gemini' else ['user', 'assistant'])
        content = message.get('parts') if kind == 'gemini' else message['content']
        if isinstance(content, str): all_text.append(content); continue
        for block in content:
            if kind == 'responses':
                assert block['type'] in ['input_text', 'input_image']
                if block['type'] == 'input_image':
                    assert block['detail'] == 'auto'; images.append(base64.b64decode(block['image_url'].split(',', 1)[1], validate=True))
                else: all_text.append(block['text'])
            elif kind == 'anthropic':
                assert block['type'] in ['text', 'image']
                if block['type'] == 'image':
                    source = block['source']; assert source['type'] == 'base64' and source['media_type'] == 'image/png'
                    images.append(base64.b64decode(source['data'], validate=True))
                else: all_text.append(block['text'])
            elif kind == 'gemini':
                assert set(block) in [{'text'}, {'inlineData'}]
                if 'inlineData' in block:
                    source = block['inlineData']; assert source['mimeType'] == 'image/png'
                    images.append(base64.b64decode(source['data'], validate=True))
                else: all_text.append(block['text'])
            else:
                assert block['type'] in ['text', 'image_url']
                if block['type'] == 'image_url': images.append(base64.b64decode(block['image_url']['url'].split(',', 1)[1], validate=True))
                else: all_text.append(block['text'])
    assert roles and roles[-1] == 'user'
    if kind in ['anthropic', 'gemini']: assert all(a != b for a, b in zip(roles, roles[1:]))
    assert all(image.startswith(b'\x89PNG\r\n\x1a\n') for image in images)
    text = '\n'.join(all_text)
    assert all(marker not in text for marker in ['NATIVE_LOCAL_TITLE_NEVER', 'NATIVE_RAW_METADATA_NEVER', 'NATIVE_USER_NEVER', 'HIDDEN_THOUGHT_NEVER', 'opaque-signature-never'])
    if action in ['success', 'history']:
        assert len(images) == 1 and all(marker in text for marker in ['NATIVE_FIRST', 'EVIDENCE_NATIVE', 'NATIVE_HOST_ALLOWED'])
        assert ('NATIVE_REPLY_ONE' in text) == (action == 'history')
    else:
        assert not images
        if action in ['followup', 'revoked', 'test']:
            assert all(marker not in text for marker in ['EVIDENCE_NATIVE', 'NATIVE_HOST_ALLOWED', 'NATIVE_REPLY_ONE'])
        if action == 'followup': assert 'NATIVE_FOLLOWUP' in text and 'NATIVE_FIRST' not in text
        if action == 'revoked': assert 'NATIVE_FIRST' in text and 'NATIVE_REVOKED' in text and 'NATIVE_FOLLOWUP' not in text
        if action == 'test': assert len(messages) == 1 and text.endswith('Reply OK.')
    native_checks[kind + ':' + action] = True


def native_response(kind, action):
    # Native provider envelopes include non-text blocks which must never become
    # displayed commands or be silently replayed as conversation state.
    if kind == 'chatCompletions':
        reply = {'choices': [{'finish_reason': 'stop', 'message': {'role': 'assistant', 'content': 'NATIVE_REPLY_ONE\nNATIVE_REPLY_TWO', 'tool_calls': None, 'refusal': None}}]}
        if action == 'blocked': reply['choices'][0]['finish_reason'] = 'content_filter'
        if action == 'incomplete': reply['choices'][0]['finish_reason'] = 'length'
        if action == 'tool': reply['choices'][0]['message']['tool_calls'] = [{'type': 'function', 'function': {'name': 'not_allowed'}}]
    elif kind == 'responses':
        reply = {'id': 'response-never-reused', 'status': 'completed', 'output': [{'type': 'reasoning', 'summary': [{'type': 'summary_text', 'text': 'HIDDEN_THOUGHT_NEVER'}], 'encrypted_content': 'opaque-signature-never'}, {'type': 'message', 'role': 'assistant', 'status': 'completed', 'content': [{'type': 'output_text', 'text': 'NATIVE_REPLY_ONE'}, {'type': 'output_text', 'text': 'NATIVE_REPLY_TWO'}]}]}
        if action == 'blocked': reply['output'][1]['content'] = [{'type': 'refusal', 'refusal': 'SERVER_SECRET_NEVER'}]
        if action == 'incomplete': reply['status'] = 'incomplete'
        if action == 'tool': reply['output'].append({'type': 'function_call', 'name': 'not_allowed', 'arguments': '{}'})
    elif kind == 'anthropic':
        reply = {'id': 'message-never-reused', 'type': 'message', 'role': 'assistant', 'stop_reason': 'end_turn', 'content': [{'type': 'thinking', 'thinking': 'HIDDEN_THOUGHT_NEVER', 'signature': 'opaque-signature-never'}, {'type': 'redacted_thinking', 'data': 'opaque-signature-never'}, {'type': 'text', 'text': 'NATIVE_REPLY_ONE'}, {'type': 'text', 'text': 'NATIVE_REPLY_TWO'}]}
        if action == 'blocked': reply['stop_reason'] = 'refusal'
        if action == 'incomplete': reply['stop_reason'] = 'max_tokens'
        if action == 'tool': reply['content'].append({'type': 'tool_use', 'name': 'not_allowed', 'input': {}})
    else:
        reply = {'candidates': [{'index': 0, 'finishReason': 'STOP', 'content': {'role': 'model', 'parts': [{'text': 'HIDDEN_THOUGHT_NEVER', 'thought': True, 'thoughtSignature': 'opaque-signature-never'}, {'text': 'NATIVE_REPLY_ONE'}, {'text': 'NATIVE_REPLY_TWO'}]}}]}
        if action == 'blocked': reply = {'promptFeedback': {'blockReason': 'SAFETY'}}
        if action == 'incomplete': reply['candidates'][0]['finishReason'] = 'MAX_TOKENS'
        if action == 'tool': reply['candidates'][0]['content']['parts'].append({'functionCall': {'name': 'not_allowed', 'args': {}}})
    if action == 'invalid': return 200, b'SERVER_SECRET_NEVER: invalid JSON'
    if action == 'slow': time.sleep(1.5)
    status = {'unauthorized': 401, 'redirect': 302, 'limited': 429}.get(action, 200)
    if status != 200: reply = {'error': {'message': 'SERVER_SECRET_NEVER'}}
    return status, json.dumps(reply).encode()

def provider_response(preset, action, payload, headers):
    anthropic = preset in ['kimiCodeCN', 'kimiCodeGlobal', 'minimaxCN', 'minimaxGlobal']
    models = {'kimiCodeCN': 'kimi-for-coding', 'kimiCodeGlobal': 'kimi-for-coding', 'deepseek': 'deepseek-flash', 'minimaxCN': 'MiniMax-M3.1-Flash', 'minimaxGlobal': 'MiniMax-M3.1-Flash', 'glm': 'glm-5.3', 'glmCoding': 'glm-5.3'}
    assert payload['model'] == models[preset]
    assert payload['max_tokens'] == (8192 if action == 'next' else 16384)
    assert 'max_completion_tokens' not in payload and 'store' not in payload
    assert payload['stream'] is False and 'tools' not in payload
    assert headers.get('User-Agent', '').startswith('OShell/')
    expected_key = 'synthetic-provider-key-' + preset
    if anthropic:
        assert headers.get('x-api-key') == expected_key and headers.get('anthropic-version') == '2023-06-01' and headers.get('Authorization') is None
        assert isinstance(payload['system'], str)
        text = '\n'.join(block['text'] for message in payload['messages'] for block in message['content'])
    else:
        assert headers.get('Authorization') == 'Bearer ' + expected_key and headers.get('x-api-key') is None
        assert payload['messages'][0]['role'] == 'system'
        text = '\n'.join(message['content'] for message in payload['messages'][1:])
    assert all(marker not in text for marker in ['PROVIDER_LOCAL_NEVER', 'PROVIDER_METADATA_NEVER', 'PROVIDER_HOST_NEVER', 'PROVIDER_REASONING_NEVER', 'OLD_PROVIDER_KEY_NEVER', 'PROVIDER_REPLY'])
    if action == 'first': assert 'PROVIDER_FIRST' in text and 'PROVIDER_EVIDENCE' in text
    else:
        assert 'PROVIDER_FIRST' not in text and 'PROVIDER_EVIDENCE' not in text
        if action == 'next': assert 'PROVIDER_NEXT' in text
        if action == 'test': assert text.endswith('Reply OK.')
    provider_checks[preset + ':' + action] = True
    if action == 'denied': return 403, b'{"error":{"message":"SERVER_SECRET_NEVER"}}'
    if anthropic:
        body = {'type': 'message', 'role': 'assistant', 'stop_reason': 'end_turn', 'content': [{'type': 'thinking', 'thinking': 'PROVIDER_REASONING_NEVER'}, {'type': 'text', 'text': 'PROVIDER_REPLY'}]}
    else:
        body = {'choices': [{'finish_reason': 'stop', 'message': {'role': 'assistant', 'content': 'PROVIDER_REPLY', 'reasoning_content': 'PROVIDER_REASONING_NEVER'}}]}
    return 200, json.dumps(body).encode()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        # A followed 302 commonly changes POST into GET; count that escape too.
        facts['requests'] += 1
        if self.path == '/sink': facts['sinkRequests'] += 1
        native_errors.append('unexpected GET')
        self.send_response(500); self.end_headers()
    def do_POST(self):
        facts['requests'] += 1
        if self.path == '/sink': facts['sinkRequests'] += 1
        data = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        payload = json.loads(data)
        captures.append((self.path, data, hashlib.sha256(data).hexdigest()))
        facts['redacted'] &= b'fixture-password' not in data and b'synthetic-ai-key' not in data and b'synthetic-provider-key-' not in data and b'OLD_PROVIDER_KEY_NEVER' not in data
        is_native = self.path.startswith('/native/')
        is_provider = self.path.startswith('/provider/')
        facts['authCorrect'] &= self.headers.get('User-Agent', '').startswith('OShell/')
        if not is_native and not is_provider: facts['authCorrect'] &= self.headers.get('Authorization') == 'Bearer synthetic-ai-key'
        facts['images'] |= b'image_url' in data
        if not is_native and not is_provider: facts['boundedOutput'] &= payload.get('max_completion_tokens') == 4096
        status = 200
        text = '示例响应（本机模拟服务，未调用外部模型）\n\n初步判断：Nginx 配置校验失败。\n\n证据：附加输出包含 syntax error。\n\n待确认：配置文件路径及 Nginx 版本。\n\n下一步：检查配置。命令尚未执行。\n```bash\nnginx -t\n```'
        if self.path == '/consent': text = 'DERIVED_FIXTURE: synthetic analysis, not executed.'
        body = json.dumps({'choices': [{'message': {'role': 'assistant', 'content': text}}]}).encode()
        if self.path == '/success': time.sleep(.25)
        if self.path == '/slow': facts['slowRequests'] += 1; time.sleep(1.5)
        if self.path == '/error': status, body = 401, b'{}'
        if self.path == '/retry' and sum(path == '/retry' for path, _, _ in captures) == 1: status, body = 503, b'{}'
        if self.path == '/large': body = b'x' * (3 * 1024 * 1024)
        if self.path == '/redirect': status, body = 302, b''
        if is_native:
            _, _, kind, action, *_ = self.path.split('/')
            try:
                inspect_native(kind, action, payload, self.headers, self.path)
                status, body = native_response(kind, action)
            except Exception as error:
                native_errors.append(kind + ':' + action + ':' + type(error).__name__)
                status, body = 500, b'{}'
        if is_provider:
            _, _, preset, action = self.path.split('/')
            try:
                status, body = provider_response(preset, action, payload, self.headers)
            except Exception as error:
                native_errors.append('provider:' + preset + ':' + action + ':' + type(error).__name__)
                status, body = 500, b'{}'
        try:
            self.send_response(status)
            if status == 302: self.send_header('Location', f'http://127.0.0.1:{self.server.server_port}/sink')
            self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(body))); self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass

def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    fixture = ROOT / 'validation/ai-test-fixture.txt'; fixture.parent.mkdir(exist_ok=True)
    fixture.write_text(f'http://127.0.0.1:{server.server_port}')
    try:
        spec = importlib.util.spec_from_file_location('ui_runner', ROOT / 'scripts/run-ui-tests.py')
        runner = importlib.util.module_from_spec(spec); spec.loader.exec_module(runner)
        runner.run_case(ROOT / 'work/test-app/OShell.app', 'ai-assistant', 120)
        result = json.loads((ROOT / 'validation/ui-ai-assistant.json').read_text())
        assert facts['requests'] == 92 and facts['sinkRequests'] == 0 and facts['slowRequests'] == 1, facts
        assert facts['redacted'] and facts['authCorrect'] and facts['images'] and facts['boundedOutput']
        assert Counter(result['approvedDigests']) == Counter(item[2] for item in captures), 'Actual bytes differ from approved frozen bodies'
        consent = [data for path, data, _ in captures if path == '/consent']
        assert len(consent) == 4
        first, followup, selective, cleared = consent
        for marker in [b'CONSENT_A', b'EVIDENCE_A', b'HOST_ALLOWED_ONE', b'image_url']:
            assert marker in first, marker
        for data in [followup, selective, cleared]:
            assert all(marker not in data for marker in [b'EVIDENCE_A', b'HOST_ALLOWED_ONE', b'image_url', b'DERIVED_FIXTURE'])
        assert b'CONSENT_B' in followup and b'CONSENT_A' not in followup
        assert b'CONSENT_A' in selective and b'CONSENT_C' in selective and b'CONSENT_B' not in selective
        assert b'CONSENT_D' in cleared and all(marker not in cleared for marker in [b'CONSENT_A', b'CONSENT_B', b'CONSENT_C'])
        for _, data, _ in captures:
            assert all(marker not in data for marker in [b'RAW_METADATA_NEVER_SENT', b'USER_NOT_APPROVED', b'DIR_NOT_APPROVED', b'LOCAL_TITLE_ONLY', b'EDITED_QUESTION_NEVER_SENT', b'OTHER_SESSION_NEVER_SENT'])
        tested = [data for path, data, _ in captures if path == '/test']
        assert len(tested) == 1
        test_messages = json.loads(tested[0])['messages']
        assert len(test_messages) == 2 and test_messages[-1]['content'].endswith('Reply OK.')
        retried = [digest for path, _, digest in captures if path == '/retry']
        assert len(retried) == 2 and retried[0] == retried[1], 'Retry must explicitly approve unchanged bytes'
        assert not native_errors, native_errors
        assert len(native_checks) == 52, native_checks
        assert len(provider_checks) == 28, provider_checks
        facts.update({'nativeProtocolCases': len(native_checks), 'providerCases': len(provider_checks), 'exactApprovedBytes': True, 'noUnapprovedRequests': True, 'noImplicitHistoryOrIdentity': True, 'revokedSourcesAndDerivedResponsesExcluded': True, 'connectionTestFixedScope': True})
        (ROOT / 'validation/ai-transport.json').write_text(json.dumps({'passed': True, 'checks': facts, 'nativeProtocolChecks': native_checks, 'providerChecks': provider_checks, 'requests': [{'path': path, 'sha256': digest, 'bytes': len(data)} for path, data, digest in captures]}, indent=2))
        print('AI transport checks passed:', facts)
    finally:
        fixture.unlink(missing_ok=True); server.shutdown(); server.server_close()

if __name__ == '__main__': main()
