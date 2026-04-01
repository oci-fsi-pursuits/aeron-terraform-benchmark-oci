#!/usr/bin/env python3
"""
Pull ~/benchmark-results/terraform-matrix-summary.json from the controller via SSH.
Used by Terraform local-exec so `terraform output` can surface median latencies.
Exits 0 even on failure (writes minimal JSON); stderr has details.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


def main() -> int:
    key = os.environ.get("TF_SSH_KEY", "")
    host = os.environ.get("TF_MATRIX_CONTROLLER_HOST", "").strip()
    user = os.environ.get("TF_MATRIX_SSH_USER", "ubuntu").strip()
    out_path = Path(os.environ.get("TF_MATRIX_OUT", ".terraform-matrix-summary.json")).resolve()
    remote = f"/home/{user}/benchmark-results/terraform-matrix-summary.json"

    err = []

    if not key or not host:
        err.append("TF_SSH_KEY or TF_MATRIX_CONTROLLER_HOST missing; skip pull")
    else:
        try:
            out_path.parent.mkdir(parents=True, exist_ok=True)
            fd, key_path = tempfile.mkstemp(prefix="tf-matrix-", suffix=".pem", text=True)
            os.close(fd)
            key_file = Path(key_path)
            key_file.write_text(key, encoding="utf-8")
            try:
                os.chmod(key_file, 0o600)
            except OSError:
                pass
            cmd = [
                "ssh",
                "-i",
                str(key_file),
                "-o",
                "StrictHostKeyChecking=no",
                "-o",
                "BatchMode=yes",
                "-o",
                "ConnectTimeout=30",
                f"{user}@{host}",
                f"cat {remote}",
            ]
            r = subprocess.run(cmd, capture_output=True, timeout=120, text=True)
            key_file.unlink(missing_ok=True)
            if r.returncode == 0 and r.stdout.strip():
                out_path.write_text(r.stdout, encoding="utf-8")
                print(f"Pulled matrix summary to {out_path}", file=sys.stderr)
                return 0
            err.append(f"ssh failed rc={r.returncode} stderr={r.stderr[:500]!r}")
        except Exception as e:
            err.append(str(e))

    stub = {
        "_pull_failed": True,
        "errors": err,
        "hint": f"Manually: ssh -i <key> {user}@{host or '<controller>'} 'cat {remote}'",
    }
    out_path.write_text(json.dumps(stub, indent=2), encoding="utf-8")
    for line in err:
        print(line, file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
