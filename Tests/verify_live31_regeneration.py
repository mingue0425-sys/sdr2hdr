#!/usr/bin/env python3
"""Regenerate LIVE31 provenance from pinned inputs and compare canonically."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GENERATOR = ROOT / "Tests/recover_live31_source_provenance.py"
COMMITTED = ROOT / "results/live31-source-provenance-recovery.json"
AUTHORITY = ROOT / "config/live31-source-authority-index.json"


def canonical(path: Path) -> str:
    return json.dumps(
        json.loads(path.read_text(encoding="utf-8")),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )


def main() -> int:
    with tempfile.TemporaryDirectory(dir=ROOT, prefix=".live31-regeneration-") as temporary:
        generated = Path(temporary) / "live31.json"
        generated_doc = Path(temporary) / "live31.md"
        result = subprocess.run(
            [
                sys.executable,
                str(GENERATOR),
                "--authority-index",
                str(AUTHORITY.relative_to(ROOT)),
                "--output",
                str(generated.relative_to(ROOT)),
                "--doc",
                str(generated_doc.relative_to(ROOT)),
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        if result.returncode != 0:
            sys.stderr.write(result.stdout)
            sys.stderr.write(result.stderr)
            return result.returncode
        if canonical(generated) != canonical(COMMITTED):
            print("LIVE31 regeneration: FAIL: canonical regenerated artifact differs")
            return 1
    print("LIVE31 regeneration: PASS")
    print("recovery exit: 0")
    print("canonical regenerated artifact == canonical committed artifact")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
