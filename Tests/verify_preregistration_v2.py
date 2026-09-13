#!/usr/bin/env python3
"""Reproduce the v2 semantic preregistration from the current generator."""

from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
COMMITTED = ROOT / "results/calibration-rebase-preregistration-v2.json"


def canonical(path: Path) -> str:
    return json.dumps(
        json.loads(path.read_text(encoding="utf-8")),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )


def main() -> int:
    if not COMMITTED.is_file():
        print("v2 preregistration regeneration: FAIL: committed artifact is missing")
        return 1
    binary = ROOT / ".build/debug/HDRCalibrate"
    with tempfile.TemporaryDirectory(dir=ROOT, prefix=".preregistration-v2-") as temporary:
        generated = Path(temporary) / "calibration-rebase-preregistration-v2.json"
        command = [
            str(binary) if binary.is_file() else "swift",
        ]
        if not binary.is_file():
            command.extend(["run", "HDRCalibrate"])
        command.extend([
            "preregister-v2",
            "--output",
            str(generated.relative_to(ROOT)),
        ])
        result = subprocess.run(
            command,
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        if result.returncode != 0:
            print(result.stdout, end="")
            print(result.stderr, end="")
            return result.returncode
        regenerated = json.loads(generated.read_text(encoding="utf-8"))
        if regenerated.get("objectiveEvaluations") != 0:
            print("v2 preregistration regeneration: FAIL: objective count is nonzero")
            return 1
        if regenerated.get("corpusDefinitionHash") != "NOT_YET_CREATED":
            print("v2 preregistration regeneration: FAIL: corpus identity was created")
            return 1
        if regenerated.get("experimentBindingHash") != "NOT_YET_CREATED":
            print("v2 preregistration regeneration: FAIL: experiment identity was created")
            return 1
        if canonical(generated) != canonical(COMMITTED):
            print("v2 preregistration regeneration: FAIL: committed artifact differs")
            return 1
    print("v2 preregistration regeneration: PASS")
    print("canonical regenerated artifact == canonical committed artifact")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
