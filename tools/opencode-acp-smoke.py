#!/usr/bin/env python3
"""Exercise installed OpenCode ACP using disposable runtime-owned state only."""
import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import tempfile
import time


def main():
    output = Path(os.environ.get("SPICA_OPENCODE_EVIDENCE", ".artifacts/opencode-acp"))
    output.mkdir(parents=True, exist_ok=True)
    executable = shutil.which("opencode")
    with tempfile.TemporaryDirectory(prefix="spica-opencode-") as root:
        root = Path(root)
        workspace = root / "workspace"
        workspace.mkdir()
        env = os.environ.copy()
        for key in list(env):
            if key.startswith("OPENCODE_") or any(word in key.upper() for word in ("TOKEN", "API_KEY", "AUTH", "SECRET")):
                del env[key]
        env.update(HOME=str(root), XDG_CONFIG_HOME=str(root / "config"), XDG_DATA_HOME=str(root / "data"), XDG_STATE_HOME=str(root / "state"), XDG_CACHE_HOME=str(root / "cache"))
        consumer = os.environ.get("SPICA_OPENCODE_CONSUMER")
        if consumer:
            with (output / "adapter-consumer.log").open("w") as log:
                command = [str(Path(consumer).resolve()), executable, str(workspace)]
                if os.environ.get("SPICA_OPENCODE_LIVE") == "1":
                    command.append("live")
                subprocess.run(command, env=env, cwd=workspace, stdout=log, stderr=subprocess.STDOUT, timeout=45, check=True)
        with (output / "stderr.log").open("w") as errors, (output / "protocol.jsonl").open("w") as log:
            process = subprocess.Popen([executable, "acp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors, cwd=workspace, env=env, text=True, bufsize=1)
            selector = selectors.DefaultSelector()
            selector.register(process.stdout, selectors.EVENT_READ)
            sequence = 0
            def rpc(method, params, notification=False):
                nonlocal sequence
                sequence += 1
                request = dict(jsonrpc="2.0", method=method, params=params)
                if not notification:
                    request["id"] = sequence
                log.write(json.dumps(dict(direction="send", message=request)) + "\n")
                log.flush()
                process.stdin.write(json.dumps(request) + "\n")
                process.stdin.flush()
                if notification:
                    return None
                deadline = time.monotonic() + 45
                while time.monotonic() < deadline:
                    if not selector.select(timeout=max(0, deadline - time.monotonic())):
                        break
                    line = process.stdout.readline()
                    if not line:
                        raise RuntimeError(f"ACP exited: {process.poll()}")
                    message = json.loads(line)
                    log.write(json.dumps(dict(direction="receive", message=message)) + "\n")
                    log.flush()
                    if message.get("id") == sequence and "method" not in message:
                        return message
                raise TimeoutError(method)
            try:
                initialized = rpc("initialize", dict(protocolVersion=1, clientCapabilities={}, clientInfo=dict(name="spica-acp-smoke", version="1")))
                assert initialized["result"]["protocolVersion"] == 1
                assert initialized["result"]["agentCapabilities"]["loadSession"]
                invalid = rpc("session/new", dict(cwd="relative", mcpServers=[]))
                assert "error" in invalid
                created = rpc("session/new", dict(cwd=str(workspace), mcpServers=[]))
                session = created["result"]["sessionId"]
                resumed = rpc("session/resume", dict(sessionId=session, cwd=str(workspace), mcpServers=[]))
                assert "result" in resumed
                mismatch = rpc("session/resume", dict(sessionId=session, cwd=str(root), mcpServers=[]))
                assert "error" in mismatch
                selection = rpc("session/set_config_option", dict(sessionId=session, configId="model", value="spica-missing/spica-no-model"))
                assert "error" in selection
                if os.environ.get("SPICA_OPENCODE_LIVE") == "1":
                    chosen = rpc("session/set_config_option", dict(sessionId=session, configId="model", value="opencode/big-pickle"))
                    assert "result" in chosen
                    inference = rpc("session/prompt", dict(sessionId=session, prompt=[dict(type="text", text="Reply with exactly SPICA_OK. Do not use tools.")]))
                    if "error" in inference:
                        print("LIVE BLOCKER:", json.dumps(inference["error"]))
                    else:
                        assert inference["result"]["stopReason"] == "end_turn"
                        print("LIVE: explicit opencode/big-pickle prompt ended; see raw streaming frames")
                rpc("session/cancel", dict(sessionId=session), notification=True)
                closed = rpc("session/close", dict(sessionId=session))
                assert "result" in closed
                print("PASS: initialize, absolute workspace validation, create, resume, workspace mismatch, unavailable model, cancel, close; isolated account unsigned-in; inference evidence only when explicitly enabled")
            finally:
                process.stdin.close()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    process.wait(timeout=5)
                selector.close()
                print(f"ACP exit: {process.returncode}; evidence: {output}")


if __name__ == "__main__":
    main()
