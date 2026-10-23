#!/usr/bin/env python3
"""Fail an install if its source changed while the signed build was running."""
import hashlib
import json
from pathlib import Path
import sys
import subprocess

root = Path(__file__).resolve().parent.parent
if sys.argv[1] == "preflight":
    processes = subprocess.run(["pgrep", "-x", "xcodebuild"], capture_output=True, text=True)
    for pid in processes.stdout.split():
        cwd = subprocess.run(["lsof", "-a", "-p", pid, "-d", "cwd", "-Fn"], capture_output=True, text=True).stdout
        args = subprocess.run(["ps", "-p", pid, "-o", "args="], capture_output=True, text=True).stdout
        if f"n{root}\n" in cwd or str(root) in args:
            raise SystemExit(f"Refusing installation: xcodebuild PID {pid} is using this checkout.")
    sys.exit(0)
files = sorted(p for folder in ("Nano", "Nano.xcodeproj", "tools")
               for p in (root / folder).rglob("*")
               if p.is_file() and ".DS_Store" != p.name
               and "xcuserdata" not in p.parts and "__pycache__" not in p.parts)
snapshot = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
path = Path(sys.argv[2])
if sys.argv[1] == "capture":
    path.write_text(json.dumps(snapshot, sort_keys=True))
elif sys.argv[1] == "verify":
    before = json.loads(path.read_text())
    changed = sorted(name for name in before.keys() | snapshot.keys() if before.get(name) != snapshot.get(name))
    if changed:
        print("Refusing installation: source changed during the build:", file=sys.stderr)
        print("\n".join(changed), file=sys.stderr)
        sys.exit(1)
else:
    raise SystemExit("Expected capture or verify")
