#!/usr/bin/env python3
"""Run the actual NativeFactory/Host MCP consumer with disposable account state."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()
evidence = Path(sys.argv[2] if len(sys.argv) > 2 else ".artifacts/opencode-acp/host-consumer.log")
evidence.parent.mkdir(parents=True, exist_ok=True)
executable = shutil.which("opencode")
with tempfile.TemporaryDirectory(prefix="spica-opencode-host-") as temporary:
    root = Path(temporary)
    workspace = root / "workspace"
    workspace.mkdir()
    account = root / "account"
    account.mkdir()
    env = {key: value for key, value in os.environ.items() if not key.startswith("OPENCODE_") and not any(word in key.upper() for word in ("TOKEN", "API_KEY", "AUTH", "SECRET"))}
    env.update(HOME=str(account), XDG_CONFIG_HOME=str(account / "config"), XDG_DATA_HOME=str(account / "data"), XDG_CACHE_HOME=str(account / "cache"), XDG_STATE_HOME=str(account / "state"))
    with evidence.open("w") as log:
        command = [str(binary), executable, str(workspace), str(account), str(root / "spica-state")]
        log.write(f"COMMAND {command!r}\nMODEL opencode/big-pickle; readiness unknown; isolated unsigned account\n")
        log.flush()
        result = subprocess.run(command, cwd=workspace, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=180)
    print(f"Host consumer exit={result.returncode}; raw evidence={evidence}")
    sys.exit(result.returncode)
