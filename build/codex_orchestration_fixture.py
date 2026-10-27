#!/usr/bin/env python3
"""Bounded offline Codex app-server fixture for app-owned orchestration.

The fixture is a protocol responder, not a provider emulator: it sends the
same dynamic tool requests a Codex coordinator/worker would send and records
only bounded, redacted wire evidence.  Every process owns a session file;
account-level event appends are locked so concurrent children cannot clobber
one another's state.
"""
from __future__ import annotations

import fcntl
import hashlib
import json
import os
from pathlib import Path
import sys
import uuid

FORMAT = "spica-offline-codex-orchestration-v1"
MODEL = "offline-orchestration"
PROVIDER = "openai"
EFFORT = "low"
MAX_FRAME = 262_144
MAX_PROFILE = 64 * 1024
MAX_EVENTS = 512
MAX_EVENT_BYTES = 256 * 1024
MAX_SESSIONS = 32
MAX_TOOL_CALLS = 32


class FixtureError(ValueError):
    pass


def load_json(path: Path, limit: int):
    data = path.read_bytes()
    if len(data) > limit:
        raise FixtureError("fixture file exceeds bound")
    try:
        value = json.loads(data)
    except json.JSONDecodeError as exc:
        raise FixtureError("invalid fixture JSON") from exc
    if not isinstance(value, dict):
        raise FixtureError("fixture object required")
    return value


def load_json_list(path: Path, limit: int):
    data = path.read_bytes()
    if len(data) > limit:
        raise FixtureError("fixture index exceeds bound")
    try:
        value = json.loads(data)
    except json.JSONDecodeError as exc:
        raise FixtureError("invalid fixture index") from exc
    if not isinstance(value, list):
        raise FixtureError("fixture index list required")
    return value


def bounded_text(value, field: str, limit: int = 4096) -> str:
    if not isinstance(value, str) or not value or len(value.encode()) > limit:
        raise FixtureError(f"invalid bounded {field}")
    return value


class Fixture:
    def __init__(self, account: Path):
        self.account = account.resolve(strict=True)
        profile_path = self.account / "orchestration-profile.json"
        if not profile_path.exists():
            profile_path = self.account / "codex-orchestration-profile.json"
        self.profile = load_json(profile_path, MAX_PROFILE)
        if self.profile.get("format") != FORMAT:
            raise FixtureError("explicit orchestration profile required")
        self.workspace = Path(bounded_text(self.profile.get("workspace"), "workspace")).resolve(strict=True)
        if self.workspace != Path.cwd().resolve():
            raise FixtureError("fixture workspace mismatch")
        self.model = self.profile.get("model", MODEL)
        self.provider = self.profile.get("model_provider", PROVIDER)
        self.effort = self.profile.get("effort", EFFORT)
        bounded_text(self.model, "model", 128)
        bounded_text(self.provider, "model_provider", 128)
        bounded_text(self.effort, "effort", 64)
        role = self.profile.get("role", "auto")
        if role not in {"auto", "coordinator", "child"}:
            raise FixtureError("invalid fixture role")
        self.role = role
        self.mode = self.profile.get("mode", "complete")
        if self.mode not in {"complete", "cancel", "cancel-start", "cancel-refuse", "cancel-hang"}:
            raise FixtureError("invalid fixture mode")
        self.pid = os.getpid()
        self.session_token = uuid.uuid4().hex
        self.session_id = "fixture-session-" + self.session_token
        self.thread_id: str | None = None
        self.turn_id: str | None = None
        self.next_id = 1000
        self.tool_calls = 0
        self.sent_calls: dict[str, dict] = {}
        self.pending_turn = False
        self.sessions = self.account / "orchestration-sessions"
        self.sessions.mkdir(mode=0o700, exist_ok=True)
        self.thread_index = self.account / "orchestration-threads.json"
        self.session_path = self.sessions / f"{self.pid}-{self.session_token}.json"
        self.events_path = self.account / "orchestration-events.jsonl"
        self.lock_path = self.account / "orchestration-events.lock"
        self.lock = self.lock_path.open("a+")
        self._save_session({"session_id": self.session_id, "pid": self.pid, "thread": None, "turns": 0})

    def _remember_thread(self, thread: str):
        """Publish a tiny append-safe thread index for restart/resume tests."""
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        try:
            index = []
            if self.thread_index.exists():
                value = json.loads(self.thread_index.read_text(encoding="utf-8"))
                if not isinstance(value, list):
                    raise FixtureError("invalid thread index")
                index = [item for item in value if isinstance(item, str)]
            if thread not in index:
                if len(index) >= MAX_SESSIONS:
                    raise FixtureError("fixture thread bound exceeded")
                index.append(thread)
            temporary = self.thread_index.with_suffix(".tmp")
            temporary.write_text(json.dumps(index, separators=(",", ":")), encoding="utf-8")
            temporary.replace(self.thread_index)
        finally:
            fcntl.flock(self.lock, fcntl.LOCK_UN)

    def _save_session(self, state: dict):
        encoded = json.dumps(state, ensure_ascii=False, separators=(",", ":"))
        if len(encoded.encode()) > 8192:
            raise FixtureError("session state bound exceeded")
        temp = self.session_path.with_suffix(".tmp")
        temp.write_text(encoded, encoding="utf-8")
        temp.replace(self.session_path)

    def record(self, method: str, **values):
        entry = {"method": method, "pid": self.pid, "session_id": self.session_id, **values}
        encoded = (json.dumps(entry, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
        if len(encoded) > 4096:
            raise FixtureError("fixture event exceeds bound")
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        try:
            current = self.events_path.stat().st_size if self.events_path.exists() else 0
            if current + len(encoded) > MAX_EVENT_BYTES:
                raise FixtureError("fixture event log bound exceeded")
            with self.events_path.open("ab") as output:
                output.write(encoded)
            with self.events_path.open("rb") as events:
                count = sum(1 for _ in events)
            if count > MAX_EVENTS:
                raise FixtureError("fixture event count bound exceeded")
        finally:
            fcntl.flock(self.lock, fcntl.LOCK_UN)

    @staticmethod
    def emit(value: dict):
        sys.stdout.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n")
        sys.stdout.flush()

    def reply(self, request: dict, result):
        self.emit({"id": request["id"], "result": result})

    def error(self, request: dict, message: str, code: int = -32602):
        self.emit({"id": request.get("id"), "error": {"code": code, "message": message}})

    def validate_request(self, request: dict):
        if not isinstance(request, dict) or "method" not in request:
            raise FixtureError("request envelope required")
        if "id" in request and not isinstance(request["id"], (int, str)):
            raise FixtureError("bounded request id required")
        if "params" in request and not isinstance(request["params"], dict):
            raise FixtureError("request params object required")

    def selection_ok(self, params: dict, *, require_thread=False):
        if params.get("cwd") != str(self.workspace) or params.get("model") != self.model:
            raise FixtureError("exact fixture selection required")
        if params.get("modelProvider", self.provider) != self.provider:
            raise FixtureError("exact fixture provider required")
        config = params.get("config", {})
        if config.get("model_reasoning_effort", params.get("effort", self.effort)) != self.effort:
            raise FixtureError("exact fixture effort required")
        if require_thread and params.get("threadId") != self.thread_id:
            raise FixtureError("exact fixture thread required")

    def receive(self, request: dict):
        self.validate_request(request)
        method = request["method"]
        params = request.get("params", {})
        if "id" not in request:
            if method == "initialized":
                self.record(method)
                return
            raise FixtureError("request id required")
        if method == "initialize":
            self.record(method, request_id=request["id"])
            self.reply(request, {"userAgent": "spica-offline-orchestration/0.163.0"})
        elif method == "account/read":
            self.record(method)
            self.reply(request, {"account": {"type": "chatgpt", "email": "offline-orchestration@example.invalid", "planType": "fixture"}, "requiresOpenaiAuth": False})
        elif method == "model/list":
            self.record(method)
            self.reply(request, {"data": [{"id": self.model, "model": self.model, "displayName": "Offline Codex orchestration fixture", "defaultReasoningEffort": self.effort, "supportedReasoningEfforts": [{"reasoningEffort": self.effort}]}], "nextCursor": None})
        elif method in {"thread/start", "thread/resume"}:
            self.selection_ok(params)
            if method == "thread/resume":
                thread = bounded_text(params.get("threadId"), "threadId", 256)
                known = []
                if self.thread_index.exists():
                    known = load_json_list(self.thread_index, 8192)
                if thread not in known and thread != self.thread_id:
                    raise FixtureError("unknown fixture thread")
            else:
                thread = f"fixture-thread-{self.session_token}"
                self._remember_thread(thread)
            self.thread_id = thread
            self._save_session({"session_id": self.session_id, "pid": self.pid, "thread": thread, "turns": 0})
            self.record(method, thread_id=thread)
            self.reply(request, {"thread": {"id": thread}, "model": self.model, "modelProvider": self.provider, "cwd": str(self.workspace), "reasoningEffort": self.effort})
        elif method == "turn/start":
            self.start_turn(request, params)
        elif method == "turn/interrupt":
            self.interrupt(request, params)
        else:
            self.error(request, "Unsupported offline orchestration fixture method", -32601)

    def start_turn(self, request: dict, params: dict):
        self.selection_ok(params, require_thread=True)
        inputs = params.get("input")
        if not isinstance(inputs, list) or len(inputs) != 1 or not isinstance(inputs[0], dict) or inputs[0].get("type") != "text":
            raise FixtureError("exact fixture turn input required")
        prompt = bounded_text(inputs[0].get("text"), "prompt", 64 * 1024)
        if self.pending_turn:
            raise FixtureError("fixture turn already active")
        self.pending_turn = True
        self.turn_id = f"{self.thread_id}-turn-1"
        self.record("turn/start", turn_id=self.turn_id, prompt_bytes=len(prompt.encode()), prompt_sha256=hashlib.sha256(prompt.encode()).hexdigest())
        self.reply(request, {"turn": {"id": self.turn_id}})
        self.emit({"method": "turn/started", "params": {"threadId": self.thread_id, "turn": {"id": self.turn_id}}})
        role = self.role
        if role == "auto":
            role = "coordinator" if any(token in prompt.lower() for token in ("coordinator", "delegate", "task.catalog", "task_catalog")) else "child"
        if self.mode in {"cancel", "cancel-start", "cancel-refuse", "cancel-hang"}:
            self.wait_for_interrupt()
            return
        if role == "coordinator":
            self.run_coordinator(prompt)
        else:
            self.run_child(prompt)
        self.complete("completed")

    def profile_packets(self, prompt: str = ""):
        packets = self.profile.get("packets")
        if packets is None and prompt:
            # orchestration_smoke embeds the exact request objects in its
            # prompt. Reading those objects keeps selection/workspace IDs
            # authoritative without inventing a second app contract.
            packets = []
            json_lines = 0
            packet_lines = 0
            json_errors = 0
            for line in prompt.splitlines():
                line = line.strip()
                if not line.startswith("{"):
                    continue
                try:
                    value = json.loads(line)
                except json.JSONDecodeError:
                    json_errors += 1
                    continue
                json_lines += 1
                if isinstance(value, dict) and "packet" in value and "request_key" in value:
                    packet_lines += 1
                    packets.append(value["packet"])
            self.record("coordinator_prompt_shape", json_lines=json_lines,
                        packet_lines=packet_lines, json_errors=json_errors)
            if len(packets) != 2:
                packets = None
        if packets is None:
            packets = [
                {"purpose": "offline worker one", "prompt": "Reply exactly SPICA_CHILD_ONE_OK.", "owned_paths": ["worker-one.txt"], "acceptance": "SPICA_CHILD_ONE_OK", "result_location": "worker-one.txt"},
                {"purpose": "offline worker two", "prompt": "Reply exactly SPICA_CHILD_TWO_OK.", "owned_paths": ["worker-two.txt"], "acceptance": "SPICA_CHILD_TWO_OK", "result_location": "worker-two.txt"},
            ]
        if not isinstance(packets, list) or len(packets) != 2:
            raise FixtureError("exactly two bounded packets required")
        result = []
        for index, raw in enumerate(packets):
            if not isinstance(raw, dict):
                raise FixtureError("packet object required")
            packet = {
                "purpose": bounded_text(raw.get("purpose"), f"packet[{index}].purpose"),
                "prompt": bounded_text(raw.get("prompt"), f"packet[{index}].prompt"),
                "selection": raw.get("selection", {}),
                "owned_paths": raw.get("owned_paths"),
                "acceptance": bounded_text(raw.get("acceptance"), f"packet[{index}].acceptance"),
                "result_location": bounded_text(raw.get("result_location"), f"packet[{index}].result_location"),
                "detached": bool(raw.get("detached", False)),
                "budget": raw.get("budget", {"max_requests": 2, "max_elapsed_ms": 90000, "max_tokens": 4000}),
            }
            selection = packet["selection"]
            if not isinstance(selection, dict):
                raise FixtureError("packet selection object required")
            selection.setdefault("runtime_kind", "codex")
            selection.setdefault("required_runtime_version", "0.163.0")
            selection.setdefault("model_provider", self.provider)
            selection.setdefault("model_id", self.model)
            selection.setdefault("effort", self.effort)
            selection.setdefault("account_ref", str(self.account))
            selection.setdefault("workspace", {"value": str(self.workspace)})
            selection.setdefault("capability_revision", 1)
            if not isinstance(packet["owned_paths"], list) or len(packet["owned_paths"]) != 1:
                raise FixtureError("each packet requires one owned path")
            for path in packet["owned_paths"]:
                bounded_text(path, "owned_path", 512)
            budget = packet["budget"]
            if not isinstance(budget, dict) or not (1 <= int(budget.get("max_requests", 0)) <= 32 and 1 <= int(budget.get("max_elapsed_ms", 0)) <= 3_600_000 and 1 <= int(budget.get("max_tokens", 0)) <= 1_000_000):
                raise FixtureError("bounded packet budget required")
            result.append(packet)
        if set(result[0]["owned_paths"]) & set(result[1]["owned_paths"]):
            raise FixtureError("worker paths must be disjoint")
        return result

    def tool(self, wire_name: str, arguments: dict):
        if self.tool_calls >= MAX_TOOL_CALLS:
            raise FixtureError("fixture tool-call bound exceeded")
        if not wire_name.startswith("task_") or not isinstance(arguments, dict):
            raise FixtureError("malformed dynamic tool call")
        self.tool_calls += 1
        call_id = f"fixture-tool-{self.tool_calls}"
        request_id = self.next_id
        self.next_id += 1
        self.record("item/tool/call", request_id=request_id, call_id=call_id, tool=wire_name, argument_keys=sorted(arguments))
        self.emit({"id": request_id, "method": "item/tool/call", "params": {"callId": call_id, "tool": wire_name, "arguments": arguments, "threadId": self.thread_id, "turnId": self.turn_id}})
        response = self.read_response(request_id)
        result = response.get("result")
        if not isinstance(result, dict) or result.get("success") is not True:
            raise FixtureError("coordinator tool call failed")
        contents = result.get("contentItems")
        if not isinstance(contents, list) or len(contents) != 1 or not isinstance(contents[0], dict) or not isinstance(contents[0].get("text"), str):
            raise FixtureError("malformed dynamic tool response")
        text = contents[0]["text"]
        self.record("item/tool/reply", request_id=request_id, call_id=call_id, success=True, response_bytes=len(text.encode()), response_sha256=hashlib.sha256(text.encode()).hexdigest())
        return text

    def read_response(self, expected_id):
        while True:
            line = sys.stdin.buffer.readline(MAX_FRAME + 1)
            if not line:
                raise FixtureError("provider ended while waiting for tool reply")
            if len(line) > MAX_FRAME or not line.endswith(b"\n"):
                raise FixtureError("fixture frame bound exceeded")
            try:
                value = json.loads(line)
            except json.JSONDecodeError as exc:
                raise FixtureError("malformed tool reply") from exc
            if not isinstance(value, dict) or value.get("id") != expected_id:
                raise FixtureError("tool reply correlation mismatch")
            return value

    @staticmethod
    def parse_text(text: str):
        try:
            value = json.loads(text)
        except json.JSONDecodeError as exc:
            raise FixtureError("host tool result was not JSON") from exc
        return value

    def run_coordinator(self, prompt: str):
        # The order is deliberate: this drives discovery, two real delegations,
        # a same-key replay, and nonblocking list/wait reads through Host.
        self.parse_text(self.tool("task_catalog", {}))
        packets = self.profile_packets(prompt)
        # Keep only bounded identity evidence in the fixture trace.  This makes
        # workspace-ID admission failures diagnosable without retaining prompts
        # or packet contents in the offline provider log.
        self.record("coordinator_packets", packet_count=len(packets),
                    workspace_values=[packet.get("selection", {}).get("workspace", {}).get("value", "")
                                      for packet in packets])
        results = []
        keys = self.profile.get("request_keys")
        if keys is None:
            keys = []
            for line in prompt.splitlines():
                line = line.strip()
                if not line.startswith("{"):
                    continue
                try:
                    value = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(value, dict) and "packet" in value and "request_key" in value:
                    keys.append(value["request_key"])
            if len(keys) != 2:
                keys = ["offline-worker-one", "offline-worker-two"]
        if not isinstance(keys, list) or len(keys) != 2 or any(not isinstance(k, str) or not k for k in keys):
            raise FixtureError("two stable request keys required")
        for key, packet in zip(keys, packets):
            args = {"request_key": key, "packet": packet}
            receipt = self.parse_text(self.tool("task_delegate", args))
            results.append(receipt)
        # A retry must cross the production callback again.  The Host's durable
        # bridge identity, not this fixture, proves that the child is unchanged.
        duplicate = self.parse_text(self.tool("task_delegate", {"request_key": keys[0], "packet": packets[0]}))
        if duplicate != results[0]:
            raise FixtureError("duplicate request did not replay exact receipt")
        listed = self.parse_text(self.tool("task_list", {}))
        task_ids = self.task_ids(listed)
        if len(task_ids) < 2:
            raise FixtureError("task.list did not expose two children")
        for task_id in task_ids[:2]:
            observed = self.parse_text(self.tool("task_wait", {"task_id": task_id}))
            if self.profile.get("result_review"):
                for _ in range(7):
                    if self.task_state(observed) == "completed":
                        break
                    observed = self.parse_text(self.tool("task_wait", {"task_id": task_id}))
            if self.profile.get("result_review") and self.task_state(observed) != "completed":
                raise FixtureError("task.wait did not observe a completed child")
            if self.profile.get("result_review"):
                candidate = "offline-candidate-" + task_id
                evidence = "offline-child-observation"
                self.parse_text(self.tool("task_result", {"request_key": "offline-result-" + task_id,
                                                            "task_id": task_id, "candidate": candidate,
                                                            "evidence": evidence, "summary": "completed"}))
                self.parse_text(self.tool("task_review", {"request_key": "offline-review-" + task_id,
                                                            "task_id": task_id, "candidate": candidate,
                                                            "evidence": evidence, "disposition": "accepted"}))
        # Optional cancellation is a public task tool call; it is enabled only
        # when a profile names a real child id after observing task.list.
        if self.profile.get("cancel_first"):
            self.parse_text(self.tool("task_cancel", {"request_key": "offline-cancel", "task_id": task_ids[0], "reason": "offline fixture cancellation"}))
        self.emit({"method": "item/agentMessage/delta", "params": {"threadId": self.thread_id, "turnId": self.turn_id, "itemId": self.turn_id + "-message", "delta": "SPICA_COORDINATOR_OK"}})

    def task_ids(self, value):
        ids = []
        def visit(node):
            if isinstance(node, dict):
                for key, child in node.items():
                    if key in {"run", "task_id", "id"} and isinstance(child, dict) and isinstance(child.get("value"), str):
                        if child["value"] not in ids:
                            ids.append(child["value"])
                    visit(child)
            elif isinstance(node, list):
                for child in node:
                    visit(child)
        visit(value)
        return [value for value in ids if value]

    @staticmethod
    def task_state(value):
        if isinstance(value, dict):
            state = value.get("state")
            if isinstance(state, str) and state in {"queued", "starting", "streaming", "completed", "failed", "cancelled", "unknown", "interrupted"}:
                return state
            for child in value.values():
                result = Fixture.task_state(child)
                if result is not None:
                    return result
        elif isinstance(value, list):
            for child in value:
                result = Fixture.task_state(child)
                if result is not None:
                    return result
        return None

    def run_child(self, prompt: str):
        marker = self.profile.get("child_marker", "SPICA_CHILD_OK")
        bounded_text(marker, "child_marker", 4096)
        self.emit({"method": "item/agentMessage/delta", "params": {"threadId": self.thread_id, "turnId": self.turn_id, "itemId": self.turn_id + "-message", "delta": marker}})

    def wait_for_interrupt(self):
        line = sys.stdin.buffer.readline(MAX_FRAME + 1)
        if not line:
            raise FixtureError("cancellation fixture ended without interrupt")
        try:
            request = json.loads(line)
        except json.JSONDecodeError as exc:
            raise FixtureError("malformed interrupt") from exc
        if request.get("method") != "turn/interrupt" or request.get("params", {}).get("threadId") != self.thread_id or request.get("params", {}).get("turnId") != self.turn_id:
            raise FixtureError("interrupt correlation mismatch")
        self.record("turn/interrupt", turn_id=self.turn_id)
        if self.mode == "cancel-hang":
            return
        if self.mode == "cancel-refuse":
            self.error(request, "Offline synthetic interrupt refused; tool state unknown.", -32000)
            return
        self.reply(request, {})
        self.complete("interrupted")

    def interrupt(self, request: dict, params: dict):
        """Handle a correctly correlated interrupt arriving outside the gate."""
        if not self.pending_turn or params.get("threadId") != self.thread_id or params.get("turnId") != self.turn_id:
            raise FixtureError("interrupt correlation mismatch")
        self.record("turn/interrupt", turn_id=self.turn_id)
        if self.mode == "cancel-hang":
            return
        if self.mode == "cancel-refuse":
            self.error(request, "Offline synthetic interrupt refused; tool state unknown.", -32000)
            return
        self.reply(request, {})
        self.complete("interrupted")

    def complete(self, status: str):
        if not self.pending_turn:
            return
        self.emit({"method": "turn/completed", "params": {"threadId": self.thread_id, "turn": {"id": self.turn_id, "status": status}}})
        self.pending_turn = False
        self._save_session({"session_id": self.session_id, "pid": self.pid, "thread": self.thread_id, "turns": 1})

    def run(self):
        while True:
            line = sys.stdin.buffer.readline(MAX_FRAME + 1)
            if not line:
                return
            if len(line) > MAX_FRAME or not line.endswith(b"\n"):
                raise FixtureError("fixture frame bound exceeded")
            try:
                request = json.loads(line)
            except json.JSONDecodeError as exc:
                raise FixtureError("malformed fixture frame") from exc
            self.receive(request)


def main():
    if sys.argv[1:] != ["app-server", "--stdio"] or "CODEX_HOME" not in os.environ:
        raise FixtureError("only explicit offline app-server --stdio is supported")
    Fixture(Path(os.environ["CODEX_HOME"])).run()


if __name__ == "__main__":
    try:
        main()
    except (OSError, FixtureError, KeyError, TypeError, ValueError):
        print("Offline Codex orchestration fixture refused an invalid profile or request.", file=sys.stderr)
        sys.exit(1)
