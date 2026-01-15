#!/usr/bin/env python3
import json
import os
import sys

def list_presets(base_dir, kind):
    """List configure or build presets from CMakePresets.json files."""
    key = "configurePresets" if kind == "configure" else "buildPresets"
    names = []
    
    for filename in ("CMakePresets.json", "CMakeUserPresets.json"):
        path = os.path.join(base_dir, filename)
        if not os.path.isfile(path):
            continue
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception:
            continue
        for preset in data.get(key, []):
            name = preset.get("name")
            if name and name not in names:
                names.append(name)
    
    return names

if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(1)
    
    base_dir = sys.argv[1]
    kind = sys.argv[2]
    names = list_presets(base_dir, kind)
    sys.stdout.write("\n".join(names))
