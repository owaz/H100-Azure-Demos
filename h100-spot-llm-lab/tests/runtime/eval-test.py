#!/usr/bin/env python3
"""Correctness and API-behavior evaluation for a deployed catalog model."""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from model_profile import load_catalog, resolve_profile


class EvalFailure(RuntimeError):
    pass


def load_environment(path):
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.startswith("#"):
            key, value = line.split("=", 1)
            values[key] = value
    return values


def validate_chat_response(response, require_content=True):
    if not isinstance(response, dict):
        raise EvalFailure("response is not a JSON object")
    if response.get("error"):
        raise EvalFailure(f"API error: {response['error']}")
    choices = response.get("choices")
    if not isinstance(choices, list) or len(choices) != 1:
        raise EvalFailure("response must contain exactly one choice")
    choice = choices[0]
    message = choice.get("message")
    if not isinstance(message, dict):
        raise EvalFailure("choice is missing its message")
    if require_content and not isinstance(message.get("content"), str):
        raise EvalFailure("message content is missing")
    finish_reason = choice.get("finish_reason")
    if finish_reason not in {"stop", "length", "tool_calls"}:
        raise EvalFailure(f"unexpected finish_reason: {finish_reason!r}")
    usage = response.get("usage")
    if not isinstance(usage, dict):
        raise EvalFailure("response is missing token usage")
    for key in ("prompt_tokens", "completion_tokens", "total_tokens"):
        if not isinstance(usage.get(key), int) or usage[key] < 0:
            raise EvalFailure(f"usage.{key} must be a non-negative integer")
    if usage["total_tokens"] < usage["prompt_tokens"] + usage["completion_tokens"]:
        raise EvalFailure("usage.total_tokens is inconsistent")
    return choice


def parse_stream(lines):
    content = []
    finish_reason = None
    saw_done = False
    saw_chunk = False
    for raw_line in lines:
        line = raw_line.decode("utf-8").strip()
        if not line or line.startswith(":"):
            continue
        if not line.startswith("data:"):
            raise EvalFailure(f"unexpected streaming line: {line[:120]}")
        data = line[5:].strip()
        if data == "[DONE]":
            saw_done = True
            continue
        try:
            chunk = json.loads(data)
        except json.JSONDecodeError as exc:
            raise EvalFailure(f"invalid streaming JSON: {exc}") from exc
        choices = chunk.get("choices")
        if not isinstance(choices, list) or len(choices) != 1:
            raise EvalFailure("streaming chunk must contain exactly one choice")
        saw_chunk = True
        delta = choices[0].get("delta", {})
        if isinstance(delta.get("content"), str):
            content.append(delta["content"])
        if choices[0].get("finish_reason") is not None:
            finish_reason = choices[0]["finish_reason"]
    if not saw_chunk:
        raise EvalFailure("stream contained no response chunks")
    if not saw_done:
        raise EvalFailure("stream did not end with [DONE]")
    if finish_reason not in {"stop", "length"}:
        raise EvalFailure(f"unexpected streaming finish_reason: {finish_reason!r}")
    return "".join(content)


def long_context_prompt(estimated_tokens):
    marker = "CONTEXT_MARKER_7F3A9C"
    filler = "Azure GPU inference validation filler sentence. "
    target_characters = max(estimated_tokens * 4, len(marker) + len(filler))
    repeated = (filler * ((target_characters // len(filler)) + 1))[:target_characters]
    prompt = (
        f"Remember this marker: {marker}.\n"
        f"{repeated}\n"
        "Return only the marker from the beginning of this prompt."
    )
    return marker, prompt


class Evaluator:
    def __init__(self, base_url, model_id, profile, timeout):
        self.chat_url = f"{base_url.rstrip('/')}/v1/chat/completions"
        self.model_id = model_id
        self.model = profile["model"]
        self.profile = profile["profile"]
        self.timeout = timeout
        self.chat_template_kwargs = self.model["smoke"]["chat_template_kwargs"]
        self.failures = []

    def post(self, body):
        request = urllib.request.Request(
            self.chat_url,
            json.dumps(body).encode("utf-8"),
            {"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                return json.load(response)
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise EvalFailure(f"HTTP {exc.code}: {detail[:500]}") from exc
        except (OSError, json.JSONDecodeError) as exc:
            raise EvalFailure(f"request failed: {exc}") from exc

    def chat(self, prompt, **overrides):
        body = {
            "model": "local-llm",
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": 128,
            "temperature": 0,
            "chat_template_kwargs": self.chat_template_kwargs,
        }
        if self.model["capabilities"]["reasoning"]:
            body["reasoning_effort"] = "low"
        body.update(overrides)
        response = self.post(body)
        choice = validate_chat_response(response)
        return choice["message"]["content"], response

    def run(self, name, test):
        try:
            test()
        except Exception as exc:
            self.failures.append((name, str(exc)))
            print(f"FAIL {name}: {exc}")
        else:
            print(f"PASS {name}")

    def test_instruction(self):
        content, _ = self.chat("Reply with exactly this text and nothing else: EVAL_OK")
        if content.strip() != "EVAL_OK":
            raise EvalFailure(f"expected EVAL_OK, got {content[:160]!r}")

    def test_reasoning(self):
        body = {
            "model": "local-llm",
            "messages": [{
                "role": "user",
                "content": "A box has 17 rows of 6 bolts. Return only the total number of bolts.",
            }],
            "max_tokens": 256,
            "temperature": 0,
            "reasoning_effort": "low",
        }
        response = self.post(body)
        choice = validate_chat_response(response)
        message = choice["message"]
        output = " ".join(
            value for value in (message.get("content"), message.get("reasoning_content"))
            if isinstance(value, str)
        )
        if re.search(r"(?<!\d)102(?!\d)", output) is None:
            raise EvalFailure(f"expected reasoning result 102, got {output[:240]!r}")

    def test_tools(self):
        body = {
            "model": "local-llm",
            "messages": [{
                "role": "user",
                "content": "Use read_file to read /etc/hostname. Do not answer without calling the tool.",
            }],
            "max_tokens": 256,
            "temperature": 0,
            "chat_template_kwargs": self.chat_template_kwargs,
            "tools": [{
                "type": "function",
                "function": {
                    "name": "read_file",
                    "description": "Read a UTF-8 text file",
                    "parameters": {
                        "type": "object",
                        "properties": {"path": {"type": "string"}},
                        "required": ["path"],
                        "additionalProperties": False,
                    },
                },
            }],
            "tool_choice": "required",
        }
        response = self.post(body)
        choice = validate_chat_response(response, require_content=False)
        calls = choice["message"].get("tool_calls")
        if not isinstance(calls, list) or len(calls) != 1:
            raise EvalFailure("expected exactly one tool call")
        function = calls[0].get("function", {})
        if function.get("name") != "read_file":
            raise EvalFailure(f"unexpected tool name: {function.get('name')!r}")
        try:
            arguments = json.loads(function.get("arguments", ""))
        except json.JSONDecodeError as exc:
            raise EvalFailure(f"tool arguments are not valid JSON: {exc}") from exc
        if arguments != {"path": "/etc/hostname"}:
            raise EvalFailure(f"unexpected tool arguments: {arguments!r}")

    def test_structured_output(self):
        schema = {
            "type": "object",
            "properties": {
                "status": {"type": "string", "enum": ["ready"]},
                "count": {"type": "integer", "enum": [3]},
            },
            "required": ["status", "count"],
            "additionalProperties": False,
        }
        content, _ = self.chat(
            "Return an object whose status is ready and count is 3.",
            response_format={
                "type": "json_schema",
                "json_schema": {"name": "eval_result", "strict": True, "schema": schema},
            },
        )
        try:
            result = json.loads(content)
        except json.JSONDecodeError as exc:
            raise EvalFailure(f"structured output is not valid JSON: {exc}") from exc
        if result != {"status": "ready", "count": 3}:
            raise EvalFailure(f"unexpected structured output: {result!r}")

    def test_streaming(self):
        body = {
            "model": "local-llm",
            "messages": [{
                "role": "user",
                "content": "Reply with exactly this text and nothing else: STREAM_OK",
            }],
            "max_tokens": 32,
            "temperature": 0,
            "stream": True,
            "chat_template_kwargs": self.chat_template_kwargs,
        }
        if self.model["capabilities"]["reasoning"]:
            body["reasoning_effort"] = "low"
        request = urllib.request.Request(
            self.chat_url,
            json.dumps(body).encode("utf-8"),
            {"Content-Type": "application/json", "Accept": "text/event-stream"},
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                content = parse_stream(response)
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise EvalFailure(f"streaming HTTP {exc.code}: {detail[:500]}") from exc
        except OSError as exc:
            raise EvalFailure(f"streaming request failed: {exc}") from exc
        if content.strip() != "STREAM_OK":
            raise EvalFailure(f"expected STREAM_OK, got {content[:160]!r}")

    def test_concurrency(self, concurrency):
        def request(index):
            expected = f"REQUEST_{index}_OK"
            content, _ = self.chat(
                f"Reply with exactly this text and nothing else: {expected}",
                max_tokens=32,
            )
            return expected, content.strip()

        errors = []
        with ThreadPoolExecutor(max_workers=concurrency) as executor:
            futures = [executor.submit(request, index) for index in range(concurrency)]
            for future in as_completed(futures):
                try:
                    expected, actual = future.result()
                    if actual != expected:
                        errors.append(f"{expected} returned {actual[:80]!r}")
                except Exception as exc:
                    errors.append(str(exc))
        if errors:
            raise EvalFailure("; ".join(errors))

    def test_long_context(self, estimated_tokens):
        marker, prompt = long_context_prompt(estimated_tokens)
        content, _ = self.chat(prompt, max_tokens=64)
        if content.strip() != marker:
            raise EvalFailure(f"expected {marker}, got {content[:160]!r}")


def parse_args():
    parser = argparse.ArgumentParser(
        description="Evaluate correctness and API behavior of the deployed LLM"
    )
    parser.add_argument(
        "--base-url",
        default=os.environ.get("EVAL_BASE_URL", "http://127.0.0.1:4000"),
    )
    parser.add_argument(
        "--concurrency",
        type=int,
        default=int(os.environ.get("EVAL_CONCURRENCY", "4")),
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=int(os.environ.get("EVAL_TIMEOUT", "600")),
    )
    parser.add_argument(
        "--long-context",
        action="store_true",
        default=os.environ.get("EVAL_LONG_CONTEXT") == "1",
    )
    parser.add_argument(
        "--long-context-tokens",
        type=int,
        default=int(os.environ.get("EVAL_LONG_CONTEXT_TOKENS", "32768")),
    )
    return parser.parse_args()


def main():
    args = parse_args()
    if args.concurrency < 1:
        raise SystemExit("--concurrency must be at least 1")
    if args.timeout < 1:
        raise SystemExit("--timeout must be at least 1")
    environment = load_environment(ROOT / ".env")
    try:
        model_id = environment["MODEL_ID"]
        vm_size = environment["MODEL_VM_SIZE"]
    except KeyError as exc:
        raise SystemExit(f"missing {exc.args[0]} in {ROOT / '.env'}") from exc
    profile = resolve_profile(
        load_catalog(ROOT / "config" / "models.json"),
        model_id,
        vm_size,
    )
    evaluator = Evaluator(args.base_url, model_id, profile, args.timeout)
    capabilities = profile["model"]["capabilities"]

    print(
        f"model={model_id} vm_size={vm_size} "
        f"concurrency={args.concurrency} long_context={args.long_context}"
    )
    evaluator.run("instruction following", evaluator.test_instruction)
    evaluator.run("structured JSON output", evaluator.test_structured_output)
    evaluator.run("streaming response", evaluator.test_streaming)
    evaluator.run(
        f"concurrent correctness (c={args.concurrency})",
        lambda: evaluator.test_concurrency(args.concurrency),
    )
    if capabilities["reasoning"]:
        evaluator.run("reasoning answer", evaluator.test_reasoning)
    else:
        print("SKIP reasoning answer (not declared by catalog)")
    if capabilities["tools"]:
        evaluator.run("tool call arguments", evaluator.test_tools)
    else:
        print("SKIP tool call arguments (not declared by catalog)")
    if args.long_context:
        max_tokens = profile["profile"]["max_model_len"]
        estimated_tokens = min(args.long_context_tokens, max_tokens * 3 // 4)
        if estimated_tokens < 1024:
            raise SystemExit("--long-context-tokens must be at least 1024")
        evaluator.run(
            f"long-context recall (~{estimated_tokens} tokens)",
            lambda: evaluator.test_long_context(estimated_tokens),
        )

    if evaluator.failures:
        print(f"\n{len(evaluator.failures)} evaluation(s) failed")
        return 1
    print("\nALL LLM EVALUATIONS PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
