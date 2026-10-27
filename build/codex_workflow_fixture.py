#!/usr/bin/python3
"""Bounded offline app-server fixture for the production Codex adapter.

Requires a disposable profile written by spica-ui. It never opens auth files,
executes tools, accesses the network or invokes an installed provider.
"""
from __future__ import annotations

import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sys
import time
import uuid

FORMAT = "spica-offline-codex-workflow-v1"
MODEL = "offline-workflow"
ERROR = "Offline Codex fixture quota exhausted (synthetic)."
MAX_FRAME = 6 * (64 * 1024 + 256 * 1024 + 4096) + 16 * 1024
MAX_LOG = 128 * 1024
CANCEL_MODES = {"cancel-open", "cancel-start", "cancel-refuse", "cancel-hang"}


def validate_turn_inputs(inputs):
    if not isinstance(inputs, list) or not 1 <= len(inputs) <= 9:
        raise ValueError("bounded turn inputs required")
    prompt = b""
    attachments = []
    total = 0
    for index, part in enumerate(inputs):
        if not isinstance(part, dict):
            raise ValueError("input object required")
        if part.get("type") == "text" and set(part) == {"type", "text"}:
            value = part["text"]
            if index == 0:
                prompt = value.encode("utf-8")
                if len(prompt) > 64 * 1024:
                    raise ValueError("fixture prompt bound exceeded")
                continue
            if not value.startswith("[Attached text file ") or "]\n" not in value:
                raise ValueError("attached text wrapper required")
            content = value.split("]\n", 1)[1].encode("utf-8")
            kind = "text"
        elif part.get("type") == "image" and set(part) == {"type", "url"}:
            header, encoded = part["url"].split(",", 1)
            if header not in {"data:" + mime + ";base64" for mime in {"image/png", "image/jpeg", "image/gif", "image/webp"}}:
                raise ValueError("image data URL required")
            content = base64.b64decode(encoded, validate=True)
            kind = "image"
        else:
            raise ValueError("native Codex input required")
        total += len(content)
        attachments.append(dict(type=kind, byte_length=len(content), sha256=hashlib.sha256(content).hexdigest()))
    if len(attachments) > 8 or total > 256 * 1024 or (not prompt and not attachments):
        raise ValueError("fixture attachment bound exceeded")
    return prompt, attachments


def read_json(path: Path, limit: int):
    with path.open("rb") as source:
        data = source.read(limit + 1)
    if len(data) > limit:
        raise ValueError("fixture file exceeds bound")
    return json.loads(data)


class Fixture:
    def __init__(self, account: Path):
        self.account = account.resolve(strict=True)
        self.profile = read_json(self.account / "workflow-profile.json", 4096)
        if (self.profile.get("format") != FORMAT
                or self.profile.get("mode") not in {"complete", "fail"} | CANCEL_MODES
                or Path(self.profile.get("workspace", "")).resolve() != Path.cwd().resolve()):
            raise ValueError("explicit disposable workflow profile required")
        self.state_path = self.account / "workflow-state.json"
        self.log_path = self.account / "workflow-events.jsonl"
        self.lock = (self.account / "workflow.lock").open("a")
        self.opened = None
        self.active = None
        self.gate_timeout_ms = self.profile.get("gate_timeout_ms", 10000)
        if type(self.gate_timeout_ms) is not int or not 1 <= self.gate_timeout_ms <= 15000:
            raise ValueError("bounded fixture gate deadline required")

    def gate(self, name):
        """Explicit provider-side delay; never mutate native app state."""
        self.record("fixture/gate", name=name, state="waiting")
        deadline = time.monotonic() + self.gate_timeout_ms / 1000
        while not (self.account / name).is_file():
            if time.monotonic() >= deadline:
                raise ValueError("offline fixture gate timed out")
            time.sleep(.01)
        self.record("fixture/gate", name=name, state="released")

    def record(self, method, **values):
        entry = dict(method=method, pid=os.getpid(), **values)
        data = (json.dumps(entry, ensure_ascii=False) + "\n").encode()
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        try:
            size = self.log_path.stat().st_size if self.log_path.exists() else 0
            if size + len(data) > MAX_LOG:
                raise ValueError("fixture event bound exceeded")
            with self.log_path.open("ab") as output:
                output.write(data)
        finally:
            fcntl.flock(self.lock, fcntl.LOCK_UN)

    def state(self):
        return read_json(self.state_path, 64 * 1024) if self.state_path.exists() else {}

    def save(self, state):
        temporary = self.state_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(state), encoding="utf-8")
        temporary.replace(self.state_path)

    @staticmethod
    def emit(value):
        print(json.dumps(value, ensure_ascii=False), flush=True)

    def reply(self, request, result):
        self.emit(dict(id=request["id"], result=result))

    def notify(self, method, params):
        self.emit(dict(method=method, params=params))

    def receive(self, request):
        method, params = request.get("method"), request.get("params", {})
        if method == "initialized" and "id" not in request:
            return
        if "id" not in request or not isinstance(params, dict):
            raise ValueError("request envelope required")
        if method == "initialize":
            self.record(method)
            self.reply(request, dict(userAgent="spica-offline-workflow/0.163.0"))
        elif method == "account/read":
            self.record(method)
            self.reply(request, dict(account=dict(type="chatgpt", email="offline@example.invalid", planType="fixture"), requiresOpenaiAuth=False))
        elif method == "model/list":
            self.record(method)
            self.reply(request, dict(data=[dict(id=MODEL, model=MODEL, displayName="Offline Codex workflow fixture",
                                               defaultReasoningEffort="low", supportedReasoningEfforts=[dict(reasoningEffort="low")])], nextCursor=None))
        elif method in {"thread/start", "thread/resume"}:
            if (params.get("cwd") != str(Path.cwd().resolve()) or params.get("model") != MODEL
                    or params.get("modelProvider") != "openai"
                    or params.get("config", {}).get("model_reasoning_effort") != "low"):
                raise ValueError("exact fixture selection required")
            state = self.state()
            thread = params.get("threadId") if method == "thread/resume" else "fixture-" + uuid.uuid4().hex
            if method == "thread/resume":
                if thread not in state:
                    raise ValueError("unknown fixture session")
            else:
                if len(state) >= 8:
                    raise ValueError("fixture session bound exceeded")
                state[thread] = []
                self.save(state)
            self.opened = thread
            self.record(method, thread_id=thread, prior_turns=len(state[thread]))
            if self.profile["mode"] == "cancel-open":
                self.gate("release-open")
            self.reply(request, dict(thread=dict(id=thread), model=MODEL, modelProvider="openai", cwd=params["cwd"], reasoningEffort="low"))
        elif method == "turn/start":
            if self.profile["mode"] == "cancel-open" or self.active is not None:
                raise ValueError("unexpected Start in cancellation fixture")
            thread = params.get("threadId")
            inputs = params.get("input")
            if (thread != self.opened or not isinstance(inputs, list) or not 1 <= len(inputs) <= 9
                    or params.get("model") != MODEL or params.get("effort") != "low"
                    or params.get("cwd") != str(Path.cwd().resolve())):
                raise ValueError("exact bound fixture turn required")
            prompt, attachments = validate_turn_inputs(inputs)
            state = self.state()
            prior = len(state[thread])
            if prior >= 16:
                raise ValueError("fixture turn bound exceeded")
            turn = thread + "-turn-" + str(prior + 1)
            details = dict(thread_id=thread, turn_id=turn, prior_turns=prior,
                           prompt_bytes=len(prompt), prompt_sha256=hashlib.sha256(prompt).hexdigest(), attachments=attachments)
            state[thread].append(details)
            self.save(state)
            self.record(method, **details)
            if self.profile["mode"] == "cancel-start":
                self.gate("release-start")
            self.reply(request, dict(turn=dict(id=turn)))
            self.notify("turn/started", dict(threadId=thread, turn=dict(id=turn)))
            if self.profile["mode"] in CANCEL_MODES:
                self.active = (thread, turn)
            elif self.profile["mode"] == "fail":
                self.notify("turn/completed", dict(threadId=thread, turn=dict(id=turn, status="failed",
                            error=dict(message=ERROR, codexErrorInfo="usageLimitExceeded", additionalDetails="Offline synthetic failure; no account was queried."))))
            else:
                message = f"Offline Codex fixture: turn {prior + 1}; prior turns {prior}; prompt bytes {len(prompt)}. café 世界"
                self.notify("item/agentMessage/delta", dict(threadId=thread, turnId=turn, itemId=turn + "-message", delta=message))
                self.notify("turn/completed", dict(threadId=thread, turn=dict(id=turn, status="completed")))
        elif method == "turn/interrupt":
            target = (params.get("threadId"), params.get("turnId"))
            if self.active is None or target != self.active:
                raise ValueError("interrupt must target the exact active fixture turn")
            self.record(method, thread_id=target[0], turn_id=target[1])
            if self.profile["mode"] == "cancel-refuse":
                self.emit(dict(id=request["id"], error=dict(code=-32000, message="Offline synthetic interrupt refused; tool state unknown.")))
            elif self.profile["mode"] != "cancel-hang":
                self.reply(request, {})
                self.notify("turn/completed", dict(threadId=target[0], turn=dict(id=target[1], status="interrupted")))
                self.active = None
        else:
            self.emit(dict(id=request["id"], error=dict(code=-32601, message="Unsupported offline fixture method")))


def main():
    if sys.argv[1:] != ["app-server", "--stdio"] or "CODEX_HOME" not in os.environ:
        raise ValueError("only explicit offline app-server --stdio is supported")
    fixture = Fixture(Path(os.environ["CODEX_HOME"]))
    while True:
        line = sys.stdin.buffer.readline(MAX_FRAME + 1)
        if not line:
            break
        if len(line) > MAX_FRAME or not line.endswith(b"\n"):
            raise ValueError("fixture frame bound exceeded")
        fixture.receive(json.loads(line))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError):
        print("Offline Codex workflow fixture refused an invalid profile or request.", file=sys.stderr)
        sys.exit(1)
