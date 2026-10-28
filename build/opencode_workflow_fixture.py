#!/usr/bin/python3
"""Bounded offline ACP fixture for the production OpenCode 2.1.4 adapter.

The fixture is intentionally narrower than an installed provider.  It accepts
only the ACP handshake and session/model/prompt paths used by Spica's adapter,
requires a CLI-created disposable profile, never reads provider credentials or
history, and stores prompt bytes only as lengths and SHA-256 digests.
"""
from __future__ import annotations

import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sys
import uuid

FORMAT = "spica-offline-opencode-workflow-v1"
VERSION = "2.1.4"
PROTOCOL = 1
# Explicit synthetic identities: the original workflow model, the prefixed
# routing regression, and the free GLM identity advertised by installed 2.1.4.
# None grants network or account access to this offline process.
MODELS = {("opencode", "big-pickle"), ("opencode-free", "glm-5.3-flash"),
          ("opencode", "glm-5.3-flash-free")}
EFFORT = "default"
FAILURE = "Offline synthetic OpenCode provider failure (synthetic)."
MAX_FRAME = 6 * (64 * 1024 + 256 * 1024 + 4096) + 16 * 1024
MAX_PROFILE = 8192
MAX_STATE = 128 * 1024
MAX_LOG = 256 * 1024
MAX_SESSIONS = 8
MAX_TURNS = 16


def validate_prompt_parts(parts):
    """Pinned effect-acp v1 ContentBlock consumer, deliberately strict fields.

    See packages/effect-acp/src/_generated/schema-v1.gen.ts ContentBlock and
    TextResourceContents/BlobResourceContents in the local T3 source reference.
    This validates offline wire acceptance, never model vision/PDF capability.
    """
    if not isinstance(parts, list) or not 1 <= len(parts) <= 9:
        raise ValueError("bounded ACP content array required")
    prompt = b""
    attachments = []
    total = 0
    for index, part in enumerate(parts):
        if not isinstance(part, dict):
            raise ValueError("ACP content object required")
        kind = part.get("type")
        if kind == "text" and index == 0 and set(part) == {"type", "text"}:
            prompt = part["text"].encode("utf-8")
            if len(prompt) > 64 * 1024:
                raise ValueError("fixture prompt bound exceeded")
            continue
        if kind == "image" and set(part) == {"type", "data", "mimeType"}:
            mime = part["mimeType"]
            if mime not in {"image/png", "image/jpeg", "image/gif", "image/webp"}:
                raise ValueError("unsupported image MIME")
            content = base64.b64decode(part["data"], validate=True)
        elif kind == "resource" and set(part) == {"type", "resource"}:
            resource = part["resource"]
            mime = resource.get("mimeType")
            if set(resource) == {"uri", "mimeType", "text"} and mime == "text/plain":
                content = resource["text"].encode("utf-8")
            elif set(resource) == {"uri", "mimeType", "blob"} and mime == "application/pdf":
                content = base64.b64decode(resource["blob"], validate=True)
            else:
                raise ValueError("unsupported embedded resource")
            if resource["uri"] != "spica-attachment:sha256:" + hashlib.sha256(content).hexdigest():
                raise ValueError("resource identity mismatch")
        else:
            raise ValueError("protocol-native ACP content required")
        total += len(content)
        attachments.append(dict(type=kind, mime_type=mime, byte_length=len(content), sha256=hashlib.sha256(content).hexdigest()))
    if len(attachments) > 8 or total > 256 * 1024 or (not prompt and not attachments):
        raise ValueError("fixture attachment bound exceeded")
    return prompt, attachments


def read_json(path: Path, limit: int):
    with path.open("rb") as source:
        data = source.read(limit + 1)
    if len(data) > limit:
        raise ValueError("fixture file exceeds bound")
    value = json.loads(data)
    if not isinstance(value, dict):
        raise ValueError("fixture JSON object required")
    return value


class Fixture:
    def __init__(self, account: Path):
        self.account = account.resolve(strict=True)
        self.profile = read_json(self.account / "workflow-profile.json", MAX_PROFILE)
        workspace = Path(self.profile.get("workspace", ""))
        if (self.profile.get("format") != FORMAT
                or self.profile.get("mode") not in {"complete", "fail"}
                or self.profile.get("runtime_version") != VERSION
                or self.profile.get("protocol_version") != PROTOCOL
                or (self.profile.get("model_provider"), self.profile.get("model")) not in MODELS
                or self.profile.get("effort") != EFFORT
                or not workspace.is_absolute()
                or workspace.resolve() != Path.cwd().resolve()):
            raise ValueError("explicit disposable OpenCode workflow profile required")
        self.model = f"{self.profile['model_provider']}/{self.profile['model']}"
        self.state_path = self.account / "workflow-state.json"
        self.log_path = self.account / "workflow-events.jsonl"
        self.lock = (self.account / "workflow.lock").open("a")
        self.opened: str | None = None
        self.pending: int | str | None = None
        self.seen_ids: set[int | str] = set()

    def record(self, method: str, **values) -> None:
        entry = dict(method=method, pid=os.getpid(), **values)
        data = (json.dumps(entry, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        try:
            size = self.log_path.stat().st_size if self.log_path.exists() else 0
            if size + len(data) > MAX_LOG:
                raise ValueError("fixture event bound exceeded")
            with self.log_path.open("ab") as output:
                output.write(data)
        finally:
            fcntl.flock(self.lock, fcntl.LOCK_UN)

    def state(self) -> dict:
        if not self.state_path.exists():
            return {}
        value = read_json(self.state_path, MAX_STATE)
        if any(not isinstance(key, str) or not isinstance(turns, list) for key, turns in value.items()):
            raise ValueError("invalid fixture state")
        return value

    def save(self, state: dict) -> None:
        encoded = json.dumps(state, ensure_ascii=False, separators=(",", ":")).encode()
        if len(encoded) > MAX_STATE:
            raise ValueError("fixture state bound exceeded")
        temporary = self.state_path.with_suffix(".tmp")
        temporary.write_bytes(encoded)
        temporary.replace(self.state_path)

    @staticmethod
    def emit(value: dict) -> None:
        print(json.dumps(value, ensure_ascii=False, separators=(",", ":")), flush=True)

    def reply(self, request: dict, result: dict) -> None:
        self.emit({"jsonrpc": "2.0", "id": request["id"], "result": result})

    def error(self, request: dict, code: int, message: str) -> None:
        self.emit({"jsonrpc": "2.0", "id": request["id"],
                   "error": {"code": code, "message": message}})

    def notify(self, params: dict) -> None:
        self.emit({"jsonrpc": "2.0", "method": "session/update", "params": params})

    def require_id(self, request: dict) -> int | str:
        identifier = request.get("id")
        if isinstance(identifier, bool) or not isinstance(identifier, (int, str)):
            raise ValueError("request id required")
        if identifier in self.seen_ids:
            raise ValueError("duplicate request id")
        if len(self.seen_ids) >= 32:
            raise ValueError("request id bound exceeded")
        self.seen_ids.add(identifier)
        if self.pending is not None and identifier != self.pending:
            raise ValueError("duplicate or out-of-order request id")
        return identifier

    def receive(self, request: dict) -> None:
        if not isinstance(request, dict) or request.get("jsonrpc") != "2.0":
            raise ValueError("JSON-RPC 2.0 request required")
        method = request.get("method")
        if method == "initialized" and "id" not in request:
            return
        if not isinstance(method, str):
            raise ValueError("request method required")
        if "id" not in request:
            if method != "session/cancel":
                raise ValueError("request id required")
            params = request.get("params", {})
            if not isinstance(params, dict):
                raise ValueError("request params object required")
            self.cancel(None, params)
            return
        identifier = self.require_id(request)
        params = request.get("params", {})
        if not isinstance(params, dict):
            raise ValueError("request params object required")
        self.pending = identifier
        try:
            self.dispatch(request, method, params)
        finally:
            self.pending = None

    def dispatch(self, request: dict, method: str, params: dict) -> None:
        if method == "initialize":
            if params.get("protocolVersion") != PROTOCOL:
                self.error(request, -32602, "unsupported ACP protocol version")
                return
            self.record(method)
            self.reply(request, {"protocolVersion": PROTOCOL,
                                 "agentInfo": {"name": "spica-offline-opencode", "version": VERSION},
                                 "agentCapabilities": {"sessionCapabilities": {"resume": {}},
                                                       "promptCapabilities": {"image": True, "embeddedContext": True}}})
            return
        if method in {"session/new", "session/resume"}:
            self.session(request, method, params)
            return
        if method == "session/set_config_option":
            self.configure(request, params)
            return
        if method == "session/prompt":
            self.prompt(request, params)
            return
        if method == "session/cancel":
            self.cancel(request, params)
            return
        self.error(request, -32601, "unsupported offline OpenCode fixture method")

    def validate_session_params(self, params: dict) -> None:
        if params.get("cwd") != str(Path.cwd().resolve()):
            raise ValueError("fixture workspace mismatch")
        servers = params.get("mcpServers")
        if not isinstance(servers, list) or len(servers) > 16:
            raise ValueError("fixture MCP server bound exceeded")

    def session(self, request: dict, method: str, params: dict) -> None:
        self.validate_session_params(params)
        state = self.state()
        if method == "session/new":
            if "sessionId" in params or len(state) >= MAX_SESSIONS:
                raise ValueError("invalid session/new request")
            upstream = "opencode-fixture-" + uuid.uuid4().hex
            state[upstream] = []
            self.save(state)
        else:
            upstream = params.get("sessionId")
            if not isinstance(upstream, str) or not upstream or upstream not in state:
                self.error(request, -32002, "session not found")
                return
        self.opened = upstream
        self.record(method, session_id=upstream, prior_turns=len(state[upstream]))
        self.reply(request, {"sessionId": upstream, "configOptions": [{
            "id": "model", "category": "model", "name": "Model", "type": "select",
            "currentValue": self.model,
            "options": [{"value": self.model, "name": "Offline OpenCode workflow fixture"}],
        }]})

    def configure(self, request: dict, params: dict) -> None:
        if params.get("sessionId") != self.opened or params.get("configId") != "model":
            raise ValueError("invalid model configuration request")
        if params.get("value") != self.model:
            raise ValueError("exact fixture model required")
        self.record("session/set_config_option", session_id=self.opened, config_id="model", value=params["value"])
        self.reply(request, {"configOptions": [{"id": "model", "currentValue": self.model}]})

    def prompt(self, request: dict, params: dict) -> None:
        if params.get("sessionId") != self.opened:
            raise ValueError("wrong fixture session id")
        prompts = params.get("prompt")
        prompt, attachments = validate_prompt_parts(prompts)
        state = self.state()
        if self.opened not in state or len(state[self.opened]) >= MAX_TURNS:
            raise ValueError("fixture turn bound exceeded")
        prior = len(state[self.opened])
        turn = f"{self.opened}-turn-{prior + 1}"
        details = {"session_id": self.opened, "turn_id": turn, "prior_turns": prior,
                   "prompt_bytes": len(prompt), "prompt_sha256": hashlib.sha256(prompt).hexdigest(),
                   "attachments": attachments}
        state[self.opened].append(details)
        self.save(state)
        self.record("session/prompt", **details)
        # ACP notifications must precede the response: the production adapter
        # leaves prompting state on the terminal response and ignores replay.
        if self.profile["mode"] == "complete":
            message = f"Offline OpenCode fixture: turn {prior + 1}; prior turns {prior}; prompt bytes {len(prompt)}. café 世界"
            # Installed 2.1.4 emits thought and usage notifications around text,
            # and returns usage alongside stopReason. Keep this envelope in the
            # fixture so completing one turn cannot depend on text being the
            # final upstream frame. All payloads here remain synthetic.
            self.notify({"sessionId": self.opened, "update": {"sessionUpdate": "agent_thought_chunk",
                         "messageId": turn + ":reasoning:0", "content": {"type": "text", "text": "Offline synthetic thought."}}})
            self.notify({"sessionId": self.opened, "update": {"sessionUpdate": "agent_message_chunk",
                         "messageId": turn, "content": {"type": "text", "text": message}}})
            self.notify({"sessionId": self.opened, "update": {"sessionUpdate": "usage_update",
                         "used": prior + 1, "size": 200000, "cost": {"amount": 0, "currency": "USD"}}})
            self.reply(request, {"stopReason": "end_turn", "usage": {"inputTokens": len(prompt), "outputTokens": len(message)}, "_meta": {}})
        else:
            self.reply(request, {"stopReason": FAILURE})

    def cancel(self, request: dict | None, params: dict) -> None:
        if params.get("sessionId") != self.opened:
            raise ValueError("wrong fixture session id")
        self.record("session/cancel", session_id=self.opened)
        if request is not None:
            self.reply(request, {})


def main() -> None:
    if sys.argv[1:] != ["acp"] or "OPENCODE_TEST_HOME" not in os.environ:
        raise ValueError("only explicit offline ACP -- acp is supported")
    fixture = Fixture(Path(os.environ["OPENCODE_TEST_HOME"]))
    while True:
        line = sys.stdin.buffer.readline(MAX_FRAME + 1)
        if not line:
            return
        if len(line) > MAX_FRAME or not line.endswith(b"\n"):
            raise ValueError("fixture frame bound exceeded")
        value = json.loads(line)
        fixture.receive(value)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, UnicodeError, json.JSONDecodeError):
        print("Offline OpenCode ACP fixture refused an invalid profile or request.", file=sys.stderr)
        sys.exit(1)
