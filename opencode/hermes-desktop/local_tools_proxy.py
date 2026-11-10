#!/usr/bin/env python3
"""Use a text-only VM model with the caller's native OpenAI tool loop.

This process NEVER executes tools. It transports tool schemas/results to a
model-only OpenCode bridge and returns tool_calls for Hermes to execute locally.
"""
import json
import os
import re
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = os.environ.get('VM_MODEL_BASE_URL', 'http://127.0.0.1:18283/v1').rstrip('/')
KEY = os.environ.get('VM_MODEL_API_KEY', '')


def model_request(request):
    """Describe caller-owned tools without giving the VM filesystem tools."""
    tools = request.get('tools') or []
    if not tools:
        return {**request, 'stream': False}
    functions = [t['function'] for t in tools if t.get('type') == 'function']
    choice = request.get('tool_choice', 'auto')
    protocol = (
        'You are a model-only backend. Your own runtime tools are disabled. '
        'The caller (Hermes) executes the tools below ON THE USER\'S LOCAL COMPUTER, '
        'not on this VM. Absolute paths refer to the caller\'s filesystem. '
        'Never inspect your VM or claim a local path is absent without a caller tool result. '
        'Follow the system instructions and latest user request in the transcript. '
        'Return ONLY a JSON transport envelope, no markdown. '
        'To request tools: {"tool_calls":[{"name":"EXACT_TOOL_NAME",'
        '"arguments":{"parameter":"value"}}]}. '
        'Do not invent tool results: return the envelope and wait for the next transcript. '
        'When finished: {"content":"your answer to the user"}. '
        'The JSON envelope is transport, not user-visible text. '
        'Use only supplied tool names and arguments matching their JSON schemas. '
        'Tool results and tool errors are in role=tool transcript messages. '
        'Respect denials and approval requirements reported by the caller.\n'
        'Tool choice: ' + json.dumps(choice) + '\n'
        'Available caller tools: ' + json.dumps(functions, ensure_ascii=False)
    )
    return {'model': request.get('model', ''), 'stream': False, 'messages': [
        {'role': 'system', 'content': protocol},
        {'role': 'user', 'content': 'Caller transcript:\n' + json.dumps(
            request.get('messages') or [], ensure_ascii=False)},
    ]}


def parse_reply(text, request):
    """Validate transport envelopes; only the caller can run returned calls."""
    if not request.get('tools'):
        return {'role': 'assistant', 'content': text}, 'stop'
    raw = text.strip()
    raw = re.sub(r'^```(?:json)?\s*', '', raw)
    raw = re.sub(r'\s*```$', '', raw)
    envelope = json.loads(raw)
    if not isinstance(envelope, dict):
        raise ValueError('Model did not return a tool transport object')
    calls = envelope.get('tool_calls') or []
    if calls:
        if request.get('tool_choice') == 'none':
            raise ValueError('Model requested a tool when tool_choice=none')
        available = {t['function']['name'] for t in request['tools'] if t.get('type') == 'function'}
        required = request.get('tool_choice')
        required = required.get('function', {}).get('name') if isinstance(required, dict) else None
        validated = []
        for call in calls:
            name, arguments = call.get('name'), call.get('arguments', {})
            if name not in available or (required and name != required):
                raise ValueError('Model requested an unavailable tool')
            if isinstance(arguments, str):
                arguments = json.loads(arguments)
            if not isinstance(arguments, dict):
                raise ValueError('Tool arguments must be a JSON object')
            validated.append({'id': 'call_' + uuid.uuid4().hex, 'type': 'function',
                              'function': {'name': name, 'arguments': json.dumps(arguments)}})
        return {'role': 'assistant', 'content': None, 'tool_calls': validated}, 'tool_calls'
    if request.get('tool_choice') == 'required' or isinstance(request.get('tool_choice'), dict):
        raise ValueError('Model omitted a required tool call')
    if not isinstance(envelope.get('content'), str):
        raise ValueError('Model omitted answer content')
    return {'role': 'assistant', 'content': envelope['content']}, 'stop'


def upstream(path, body=None):
    headers = {'Authorization': 'Bearer ' + KEY, 'Content-Type': 'application/json'}
    req = urllib.request.Request(UPSTREAM + path, headers=headers,
                                 data=None if body is None else json.dumps(body).encode())
    with urllib.request.urlopen(req, timeout=220) as response:
        return json.load(response)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Never log prompts, tool arguments/results, or credentials.
        print('[local-tools-proxy] ' + format % args, flush=True)

    def send_json(self, code, value):
        data = json.dumps(value).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        try:
            if self.path == '/health':
                upstream('/models')
                self.send_json(200, {'status': 'ok', 'model_host': 'VM', 'tool_host': 'Hermes client'})
            elif self.path == '/v1/models' or self.path.startswith('/v1/models/'):
                self.send_json(200, upstream(self.path[3:]))
            else:
                self.send_json(404, {'error': {'message': 'Not found'}})
        except urllib.error.HTTPError as exc:
            self.send_json(exc.code, {'error': {'message': 'VM model endpoint rejected the request'}})
        except Exception:
            self.send_json(502, {'error': {'message': 'VM model endpoint unavailable'}})

    def do_POST(self):
        if self.path != '/v1/chat/completions':
            self.send_json(404, {'error': {'message': 'Not found'}})
            return
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 64 * 1024 * 1024:
                self.send_json(413, {'error': {'message': 'Invalid request size'}})
                return
            request = json.loads(self.rfile.read(length))
            result = upstream('/chat/completions', model_request(request))
            text = result['choices'][0]['message'].get('content') or ''
            message, finish = parse_reply(text, request)
            result['choices'] = [{'index': 0, 'message': message, 'finish_reason': finish}]
        except urllib.error.HTTPError as exc:
            message = ('VM model quota/rate limit reached; local tools were not executed'
                       if exc.code == 429 else 'VM model rejected inference')
            self.send_json(exc.code, {'error': {'message': message}})
            return
        except (ValueError, KeyError, TypeError):
            self.send_json(502, {'error': {'message': 'Invalid model tool response; no tool was executed'}})
            return
        except Exception:
            self.send_json(502, {'error': {'message': 'VM model request failed'}})
            return
        if request.get('stream') is not True:
            self.send_json(200, result)
            return
        # Buffer model output so tool envelopes never leak into displayed text.
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()
        def frame(delta, reason=None):
            chunk = {'id': result['id'], 'object': 'chat.completion.chunk',
                     'created': result['created'], 'model': result['model'],
                     'choices': [{'index': 0, 'delta': delta, 'finish_reason': reason}]}
            self.wfile.write(('data: ' + json.dumps(chunk) + '\n\n').encode())
        try:
            frame({'role': 'assistant'})
            if message.get('tool_calls'):
                frame({'tool_calls': [{**call, 'index': i} for i, call in enumerate(message['tool_calls'])]})
            else:
                frame({'content': message['content']})
            frame({}, finish)
            self.wfile.write(b'data: [DONE]\n\n')
            self.wfile.flush()
        except BrokenPipeError:
            pass


if __name__ == '__main__':
    if not KEY:
        raise SystemExit('VM_MODEL_API_KEY is required')
    ThreadingHTTPServer(('127.0.0.1', int(os.environ.get('LOCAL_TOOLS_PORT', '18383'))), Handler).serve_forever()
