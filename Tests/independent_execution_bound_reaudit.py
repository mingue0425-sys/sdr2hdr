#!/usr/bin/env python3
"""Historical V3 guard retained for audit lineage only.

The old independent V3 script used to print a current PASS claim. V3 is
invalidated and this compatibility entry point now delegates to the explicit
historical artifact guard without making any semantic-completeness claim.
"""

from __future__ import annotations

import runpy
from pathlib import Path


if __name__ == "__main__":
    runpy.run_path(str(Path(__file__).with_name("verify_preregistration_v3.py")), run_name="__main__")
