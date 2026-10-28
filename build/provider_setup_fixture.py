#!/usr/bin/python3
"""Offline native setup protocol fixture. Never calls a provider or reads credentials."""
import json
import os
from pathlib import Path
import sys
import threading
import time


LOCK = threading.Lock()
ACCOUNT = Path(os.environ.get('CODEX_HOME', os.environ.get('HOME', '/tmp')))
MARKER = ACCOUNT / '.spica-fixture-signed-in'
OPENCODE = len(sys.argv) > 1 and sys.argv[1] == 'acp'
MODEL = 'setup-opencode' if OPENCODE else 'setup-codex'


def emit(value):
    with LOCK:
        print(json.dumps(value, ensure_ascii=False), flush=True)


def reply(request, result):
    emit(dict(jsonrpc='2.0', id=request['id'], result=result))


def notify(method, params):
    emit(dict(jsonrpc='2.0', method=method, params=params))


def account():
    return dict(type='chatgpt', email='fixture@example.invalid', planType='fixture') if MARKER.exists() else None


def complete_login():
    time.sleep(1.5)
    # This marker belongs only to the explicitly configured disposable fixture
    # account. It is not an auth.json and grants no external account access.
    MARKER.write_text('offline fixture only\n')
    notify('account/login/completed', dict(loginId='setup-login', success=True))
    notify('account/updated', dict(account=account(), authMode='chatgpt'))


def options(model=MODEL):
    return [dict(id='model', name='Model', category='model', type='select',
                 currentValue='opencode/' + model,
                 options=[dict(value='opencode/' + MODEL, name='Offline setup fixture')]),
            dict(id='effort', name='Effort', type='select', currentValue='default',
                 options=[dict(value='default', name='Default'), dict(value='high', name='High')])]


def main():
    for line in sys.stdin:
        request = json.loads(line)
        method, params = request.get('method'), request.get('params', {})
        if 'id' not in request:
            continue
        if method == 'initialize':
            reply(request, dict(protocolVersion=1, agentInfo=dict(name='offline-setup', version='2.1.4'), agentCapabilities=dict())
                  if OPENCODE else dict(userAgent='offline-spica-fixture/' + os.environ.get('SPICA_FIXTURE_CODEX_VERSION', '0.163.0')))
        elif method == 'account/read':
            reply(request, dict(account=account(), requiresOpenaiAuth=account() is None))
        elif method == 'model/list':
            reply(request, dict(data=[dict(id=MODEL, model=MODEL, displayName='Offline setup fixture',
                  defaultReasoningEffort='low', supportedReasoningEfforts=[dict(reasoningEffort='low'), dict(reasoningEffort='high')])], nextCursor=None))
        elif method == 'account/login/start':
            if params.get('type') == 'chatgpt':
                reply(request, dict(type='chatgpt', loginId='setup-login',
                      authUrl='https://example.invalid/spica-fixture'))
            else:
                reply(request, dict(type='chatgptDeviceCode', loginId='setup-login',
                      verificationUrl='https://example.invalid/spica-fixture', userCode='TEST-1234'))
            threading.Thread(target=complete_login, daemon=True).start()
        elif method in ('thread/start', 'thread/resume'):
            reply(request, dict(thread=dict(id=params.get('threadId', 'setup-thread')),
                  model=params['model'], modelProvider=params['modelProvider'], cwd=params['cwd'],
                  reasoningEffort=params['config']['model_reasoning_effort']))
        elif method == 'turn/start':
            reply(request, dict(turn=dict(id='setup-turn')))
            notify('turn/started', dict(threadId='setup-thread', turn=dict(id='setup-turn')))
            notify('item/agentMessage/delta', dict(threadId='setup-thread', turnId='setup-turn',
                   itemId='setup-message', delta='Offline setup worked: café 世界.'))
            notify('turn/completed', dict(threadId='setup-thread', turn=dict(id='setup-turn', status='completed')))
        elif method == 'session/new':
            reply(request, dict(sessionId='setup-session', configOptions=options()))
        elif method == 'session/set_config_option':
            reply(request, dict(configOptions=options()))
        else:
            emit(dict(jsonrpc='2.0', id=request['id'], error=dict(code=-32601, message='Offline fixture does not implement ' + str(method))))


if __name__ == '__main__':
    main()
