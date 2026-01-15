#!/usr/bin/env python3
import json
import os
import sys

def load_json(path):
    """Load JSON file, return empty dict on error."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}

def merge_dicts(parent, child):
    """Merge child dict into parent, with child values taking precedence."""
    result = dict(parent)
    for key, val in child.items():
        if key == "inherits":
            continue
        if isinstance(val, dict) and isinstance(result.get(key), dict):
            merged = dict(result[key])
            merged.update(val)
            result[key] = merged
        else:
            result[key] = val
    return result

def resolve_preset(name, presets, stack=None):
    """Resolve preset inheritance."""
    if stack is None:
        stack = []
    if name in stack:
        return {}
    preset = presets.get(name)
    if not isinstance(preset, dict):
        return {}
    
    inherits = preset.get("inherits", [])
    if isinstance(inherits, str):
        inherits = [inherits]
    
    merged = {}
    for parent in inherits:
        merged = merge_dicts(merged, resolve_preset(parent, presets, stack + [name]))
    return merge_dicts(merged, preset)

def expand_vars(val, source_dir, name):
    """Expand CMake variables in string."""
    val = val.replace("${sourceDir}", source_dir)
    val = val.replace("${presetName}", name)
    return val

def get_build_info(base_dir, preset_name):
    """Get build directory and configuration for a preset."""
    source_dir = None
    configure_presets = {}
    build_presets = {}
    
    # Load presets from both files
    for filename in ("CMakePresets.json", "CMakeUserPresets.json"):
        path = os.path.join(base_dir, filename)
        if not os.path.isfile(path):
            continue
        data = load_json(path)
        if "sourceDir" in data:
            source_dir = data.get("sourceDir")
        
        for preset in data.get("configurePresets", []):
            name = preset.get("name")
            if name:
                configure_presets[name] = preset
        
        for preset in data.get("buildPresets", []):
            name = preset.get("name")
            if name:
                build_presets[name] = preset
    
    # Resolve build and configure presets
    bp = resolve_preset(preset_name, build_presets)
    config_name = bp.get("configurePreset")
    cp = resolve_preset(config_name, configure_presets)
    
    binary_dir = bp.get("binaryDir") or cp.get("binaryDir") or ""
    configuration = bp.get("configuration", "")
    
    # Determine source directory
    source_dir = source_dir or base_dir
    if not os.path.isabs(source_dir):
        source_dir = os.path.abspath(os.path.join(base_dir, source_dir))
    
    # Expand binary directory path
    if binary_dir:
        name_for_expand = preset_name if bp.get("binaryDir") else (config_name or preset_name)
        binary_dir = expand_vars(binary_dir, source_dir, name_for_expand)
        if not os.path.isabs(binary_dir):
            binary_dir = os.path.abspath(os.path.join(base_dir, binary_dir))
    
    return binary_dir, configuration

if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(1)
    
    base_dir = sys.argv[1]
    preset_name = sys.argv[2]
    binary_dir, configuration = get_build_info(base_dir, preset_name)
    sys.stdout.write(f"{binary_dir}|{configuration}")
