#!/usr/bin/env python3
import importlib.util
import json
import re
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parent / "runtime" / "eval-test.py"
SPEC = importlib.util.spec_from_file_location("runtime_eval", MODULE_PATH)
runtime_eval = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runtime_eval)


class MockChatHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers["Content-Length"])
        body = json.loads(self.rfile.read(length))
        prompt = body["messages"][0]["content"]
        if body.get("stream"):
            chunks = [
                {"choices": [{"delta": {"content": "STREAM_"}, "finish_reason": None}]},
                {"choices": [{"delta": {"content": "OK"}, "finish_reason": "stop"}]},
            ]
            payload = "".join(
                f"data: {json.dumps(chunk)}\n\n" for chunk in chunks
            ) + "data: [DONE]\n\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(payload.encode("utf-8"))))
            self.end_headers()
            self.wfile.write(payload.encode("utf-8"))
            return

        finish_reason = "stop"
        message = {"role": "assistant"}
        if "tools" in body:
            finish_reason = "tool_calls"
            message["content"] = None
            message["tool_calls"] = [{
                "function": {
                    "name": "read_file",
                    "arguments": json.dumps({"path": "/etc/hostname"}),
                },
            }]
        elif "response_format" in body:
            message["content"] = json.dumps({"status": "ready", "count": 3})
        elif "CONTEXT_MARKER_7F3A9C" in prompt:
            message["content"] = "CONTEXT_MARKER_7F3A9C"
        else:
            match = re.search(r"nothing else: ([A-Z0-9_]+)", prompt)
            if match:
                message["content"] = match.group(1)
            elif body.get("reasoning_effort"):
                message["content"] = "102"
            else:
                message["content"] = "unexpected"
        response = {
            "choices": [{"finish_reason": finish_reason, "message": message}],
            "usage": {
                "prompt_tokens": 10,
                "completion_tokens": 2,
                "total_tokens": 12,
            },
        }
        payload = json.dumps(response).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format, *args):
        pass


class RuntimeEvalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), MockChatHandler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base_url = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def test_valid_chat_response(self):
        choice = runtime_eval.validate_chat_response({
            "choices": [{
                "finish_reason": "stop",
                "message": {"role": "assistant", "content": "ok"},
            }],
            "usage": {
                "prompt_tokens": 4,
                "completion_tokens": 1,
                "total_tokens": 5,
            },
        })
        self.assertEqual(choice["message"]["content"], "ok")

    def test_rejects_inconsistent_usage(self):
        with self.assertRaisesRegex(runtime_eval.EvalFailure, "inconsistent"):
            runtime_eval.validate_chat_response({
                "choices": [{
                    "finish_reason": "stop",
                    "message": {"role": "assistant", "content": "ok"},
                }],
                "usage": {
                    "prompt_tokens": 4,
                    "completion_tokens": 2,
                    "total_tokens": 5,
                },
            })

    def test_rejects_excess_total_tokens(self):
        with self.assertRaisesRegex(runtime_eval.EvalFailure, "inconsistent"):
            runtime_eval.validate_chat_response({
                "choices": [{
                    "finish_reason": "stop",
                    "message": {"role": "assistant", "content": "ok"},
                }],
                "usage": {
                    "prompt_tokens": 4,
                    "completion_tokens": 2,
                    "total_tokens": 100,
                },
            })

    def test_parses_stream(self):
        chunks = [
            {"choices": [{"delta": {"content": "STREAM_"}, "finish_reason": None}]},
            {"choices": [{"delta": {"content": "OK"}, "finish_reason": "stop"}]},
        ]
        lines = [
            f"data: {json.dumps(chunk)}\n".encode("utf-8")
            for chunk in chunks
        ] + [b"data: [DONE]\n"]
        self.assertEqual(runtime_eval.parse_stream(lines), "STREAM_OK")

    def test_rejects_stream_without_done(self):
        lines = [b'data: {"choices":[{"delta":{"content":"x"},"finish_reason":"stop"}]}\n']
        with self.assertRaisesRegex(runtime_eval.EvalFailure, r"\[DONE\]"):
            runtime_eval.parse_stream(lines)

    def test_rejects_duplicate_done_markers(self):
        lines = [
            b'data: {"choices":[{"delta":{"content":"x"},"finish_reason":"stop"}]}\n',
            b"data: [DONE]\n",
            b": keep-alive\n",
            b"data: [DONE]\n",
        ]
        with self.assertRaisesRegex(runtime_eval.EvalFailure, "duplicate"):
            runtime_eval.parse_stream(lines)

    def test_rejects_data_after_done(self):
        lines = [
            b'data: {"choices":[{"delta":{"content":"x"},"finish_reason":"stop"}]}\n',
            b"data: [DONE]\n",
            b'data: {"choices":[{"delta":{"content":"late"},"finish_reason":null}]}\n',
        ]
        with self.assertRaisesRegex(runtime_eval.EvalFailure, r"after \[DONE\]"):
            runtime_eval.parse_stream(lines)

    def test_long_context_prompt_preserves_marker(self):
        marker, prompt = runtime_eval.long_context_prompt(2048)
        self.assertIn(marker, prompt[:100])
        self.assertTrue(prompt.endswith("Return only the marker from the beginning of this prompt."))
        self.assertGreaterEqual(len(prompt), 2048 * 4)

    def test_tool_arguments_must_match(self):
        profile = {
            "model": {
                "smoke": {"chat_template_kwargs": {}},
                "capabilities": {"reasoning": True, "tools": True},
            },
            "profile": {},
        }
        evaluator = runtime_eval.Evaluator("http://example.test", "model", profile, 1)
        evaluator.post = lambda body: {
            "choices": [{
                "finish_reason": "tool_calls",
                "message": {
                    "content": None,
                    "tool_calls": [{
                        "function": {
                            "name": "read_file",
                            "arguments": json.dumps({"path": "/wrong"}),
                        },
                    }],
                },
            }],
            "usage": {
                "prompt_tokens": 10,
                "completion_tokens": 3,
                "total_tokens": 13,
            },
        }
        with self.assertRaisesRegex(runtime_eval.EvalFailure, "unexpected tool arguments"):
            evaluator.test_tools()

    def test_end_to_end_against_mock_endpoint(self):
        profile = {
            "model": {
                "smoke": {"chat_template_kwargs": {"enable_thinking": False}},
                "capabilities": {"reasoning": True, "tools": True},
            },
            "profile": {"max_model_len": 32768},
        }
        evaluator = runtime_eval.Evaluator(self.base_url, "model", profile, 5)
        evaluator.test_instruction()
        evaluator.test_structured_output()
        evaluator.test_streaming()
        evaluator.test_concurrency(4)
        evaluator.test_reasoning()
        evaluator.test_tools()
        evaluator.test_long_context(1024)


if __name__ == "__main__":
    unittest.main()
