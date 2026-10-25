#!/usr/bin/env python3
"""Select the public engine release matching this binding's source version."""
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parent.parent
version = re.search(r'@version "([^"]+)"', (root / "mix.exs").read_text()).group(1)
tag = json.loads((root / "engine-release.json").read_text())["release_tag"]
if tag != f"v{version}":
    raise ValueError(f"engine tag {tag} differs from binding version {version}")
print(tag)
