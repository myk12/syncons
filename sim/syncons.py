#!/usr/bin/env python3

from __future__ import annotations

import pathlib
import sys

if __package__ in (None, ""):
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from sim.runtime.cli import main


if __name__ == "__main__":
    raise SystemExit(main())
