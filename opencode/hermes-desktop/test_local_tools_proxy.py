import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch
import threading
import urllib.request

spec = importlib.util.spec_from_file_location('proxy', Path(__file__).with_name('local_tools_proxy.py'))
proxy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proxy)


class ToolTransportTests(unittest.TestCase):
    def setUp(self):
        self.request = {'model': 'opencode/example-free', 'stream': True,
                        'tools': [{'type': 'function', 'function': {
                            'name': 'read_file', 'description': 'Read a file on the caller',
                            'parameters': {'type': 'object', 'properties': {'path': {'type': 'string'}}}}}],
                        'messages': [{'role': 'user', 'content': 'Read /local/proof.txt'}]}

    def test_transports_schemas_and_results_without_executing(self):
        self.request['messages'].append({'role': 'tool', 'tool_call_id': 'call_1', 'content': 'UNIQUE-LOCAL-RESULT'})
        body = proxy.model_request(self.request)
        self.assertFalse(body['stream'])
        self.assertIn('read_file', body['messages'][0]['content'])
        self.assertIn('UNIQUE-LOCAL-RESULT', body['messages'][1]['content'])
        self.assertNotIn('tools', body)

    def test_native_call_and_final_answer_round_trip(self):
        text = json.dumps({'tool_calls': [{'name': 'read_file', 'arguments': {'path': '/local/proof.txt'}}]})
        message, finish = proxy.parse_reply(text, self.request)
        self.assertEqual(finish, 'tool_calls')
        self.assertIsNone(message['content'])
        call = message['tool_calls'][0]
        self.assertTrue(call['id'].startswith('call_'))
        self.assertEqual(json.loads(call['function']['arguments']), {'path': '/local/proof.txt'})
        final, finish = proxy.parse_reply('{"content":"Observed local file contents"}', self.request)
        self.assertEqual(finish, 'stop')
        self.assertEqual(final['content'], 'Observed local file contents')

    def test_unavailable_tools_and_invalid_arguments_refused(self):
        for text in ['{"tool_calls":[{"name":"remote_shell","arguments":{}}]}',
                     '{"tool_calls":[{"name":"read_file","arguments":[]}]}' ,
                     'not a tool envelope']:
            with self.assertRaises(ValueError):
                proxy.parse_reply(text, self.request)

    def test_tool_choice_constraints(self):
        call = '{"tool_calls":[{"name":"read_file","arguments":{}}]}'
        self.request['tool_choice'] = 'none'
        with self.assertRaises(ValueError):
            proxy.parse_reply(call, self.request)
        self.request['tool_choice'] = 'required'
        with self.assertRaises(ValueError):
            proxy.parse_reply('{"content":"pretended result"}', self.request)

    def test_plain_chat_remains_plain_chat(self):
        request = {'model': 'example', 'messages': [{'role': 'user', 'content': 'hello'}], 'stream': True}
        self.assertEqual(proxy.model_request(request)['messages'], request['messages'])
        message, finish = proxy.parse_reply('hello', request)
        self.assertEqual((message['content'], finish), ('hello', 'stop'))

    def test_streaming_emits_native_tool_deltas_not_transport_json(self):
        result = {'id': 'chatcmpl-test', 'created': 1, 'model': 'example', 'choices': [
            {'message': {'content': '{"tool_calls":[{"name":"read_file","arguments":{"path":"/local/proof"}}]}'}}]}
        server = proxy.ThreadingHTTPServer(('127.0.0.1', 0), proxy.Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        with patch.object(proxy, 'upstream', return_value=result):
            worker.start()
            try:
                req = urllib.request.Request('http://127.0.0.1:' + str(server.server_port) + '/v1/chat/completions',
                    data=json.dumps(self.request).encode(), headers={'Content-Type': 'application/json'})
                with urllib.request.urlopen(req, timeout=5) as response:
                    wire = response.read().decode()
                frames = [json.loads(line[6:]) for line in wire.splitlines()
                          if line.startswith('data: ') and line != 'data: [DONE]']
                calls = [f['choices'][0]['delta']['tool_calls'] for f in frames
                         if 'tool_calls' in f['choices'][0]['delta']]
                self.assertEqual(calls[0][0]['function']['name'], 'read_file')
                self.assertEqual(frames[-1]['choices'][0]['finish_reason'], 'tool_calls')
                self.assertTrue(wire.endswith('data: [DONE]\n\n'))
            finally:
                server.shutdown(); server.server_close(); worker.join(timeout=2)


if __name__ == '__main__':
    unittest.main()
