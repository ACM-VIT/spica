#!/usr/bin/env python3
"""Run the actual public Host consumer with disposable OpenCode-owned state."""
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
    env = {key: value for key, value in os.environ.items() if not key.startswith("OPENCODE_") and not any(word in key.upper() for word in ("TOKEN", "API_KEY", "AUTH", "SECRET"))}
    env.update(HOME=str(root), XDG_CONFIG_HOME=str(root / "config"), XDG_DATA_HOME=str(root / "data"), XDG_CACHE_HOME=str(root / "cache"), XDG_STATE_HOME=str(root / "state"))
    with evidence.open("w") as log:
        result = subprocess.run([str(binary), executable, str(workspace), str(root / "spica-state")], cwd=workspace, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=100)
    print(f"Host consumer exit={result.returncode}; raw evidence={evidence}")
    sys.exit(result.returncode)
