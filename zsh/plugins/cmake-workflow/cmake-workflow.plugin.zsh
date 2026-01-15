_cmc__find_presets_dir() {
  local dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/CMakePresets.json" || -f "$dir/CMakeUserPresets.json" ]]; then
      print -r -- "$dir"
      return 0
    fi
    dir="${dir:h}"
  done
  return 1
}

_cmc__fuzzy_filter() {
  local query="$1"
  shift
  local -a items=("$@")
  local -a out=()

  if [[ -z "$query" ]]; then
    printf '%s\n' "${items[@]}"
    return 0
  fi

  local q="${query:l}"
  local item s c i ok
  for item in "${items[@]}"; do
    s="${item:l}"
    ok=1
    for ((i=1; i<=${#q}; i++)); do
      c="${q[i]}"
      if [[ "$s" == *"$c"* ]]; then
        s="${s#*${c}}"
      else
        ok=0
        break
      fi
    done
    (( ok )) && out+=("$item")
  done

  printf '%s\n' "${out[@]}"
}

_cmc__fuzzy_pick() {
  local query="$1"
  shift
  local -a items=("$@")
  local -a matches
  matches=(${(f)"$(_cmc__fuzzy_filter "$query" "${items[@]}")"})
  if (( ${#matches[@]} == 1 )); then
    print -r -- "$matches[1]"
    return 0
  fi
  return 1
}

_cmc__resolve_preset() {
  local kind="$1"
  local input="$2"
  local -a presets
  presets=(${(f)"$(_cmc__list_presets "$kind")"})
  if [[ -z "$input" ]]; then
    return 1
  fi
  local p
  for p in "${presets[@]}"; do
    if [[ "$p" == "$input" ]]; then
      print -r -- "$input"
      return 0
    fi
  done
  _cmc__fuzzy_pick "$input" "${presets[@]}"
}

_cmc__resolve_target() {
  local preset="$1"
  local input="$2"
  local -a targets
  targets=(${(f)"$(_cmc__list_targets "$preset")"})
  if [[ -z "$input" ]]; then
    return 1
  fi
  local t
  for t in "${targets[@]}"; do
    if [[ "$t" == "$input" ]]; then
      print -r -- "$input"
      return 0
    fi
  done
  _cmc__fuzzy_pick "$input" "${targets[@]}"
}

_cmc__list_presets() {
  local kind="$1"
  local dir
  dir="$(_cmc__find_presets_dir)" || return 0

  python3 - "$dir" "$kind" <<'PY'
import json
import os
import sys

base_dir = sys.argv[1]
kind = sys.argv[2]
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

sys.stdout.write("\n".join(names))
PY
}

_cmc__build_info() {
  local preset="$1"
  local dir
  dir="$(_cmc__find_presets_dir)" || return 1

  python3 - "$dir" "$preset" <<'PY'
import json
import os
import sys

base_dir = sys.argv[1]
preset_name = sys.argv[2]

def load(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}

source_dir = None
configure_presets = {}
build_presets = {}

def upsert_presets(store, items):
    for item in items:
        name = item.get("name")
        if name:
            store[name] = item

for filename in ("CMakePresets.json", "CMakeUserPresets.json"):
    path = os.path.join(base_dir, filename)
    if not os.path.isfile(path):
        continue
    data = load(path)
    if "sourceDir" in data:
        source_dir = data.get("sourceDir")
    upsert_presets(configure_presets, data.get("configurePresets", []))
    upsert_presets(build_presets, data.get("buildPresets", []))

def merge_dicts(parent, child):
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

bp = resolve_preset(preset_name, build_presets)
config_name = bp.get("configurePreset")
cp = resolve_preset(config_name, configure_presets)

binary_dir = bp.get("binaryDir") or cp.get("binaryDir") or ""
configuration = bp.get("configuration", "")

source_dir = source_dir or base_dir
if not os.path.isabs(source_dir):
    source_dir = os.path.abspath(os.path.join(base_dir, source_dir))

def expand(val, name):
    val = val.replace("${sourceDir}", source_dir)
    val = val.replace("${presetName}", name or preset_name)
    return val

if binary_dir:
    name_for_expand = preset_name if bp.get("binaryDir") else (config_name or preset_name)
    binary_dir = expand(binary_dir, name_for_expand)
    if not os.path.isabs(binary_dir):
        binary_dir = os.path.abspath(os.path.join(base_dir, binary_dir))

sys.stdout.write(f"{binary_dir}|{configuration}")
PY
}

_cmc__list_targets() {
  local preset="$1"
  local info builddir
  info="$(_cmc__build_info "$preset")"
  builddir="${info%%|*}"

  if [[ -n "$builddir" && -f "$builddir/build.ninja" && -n ${commands[ninja]} ]]; then
    ninja -C "$builddir" -t targets 2>/dev/null | \
      sed -n 's/^\([^:][^:]*\):.*/\1/p' | \
      grep -v '\.' | \
      grep -v '^CMakeFiles' | \
      grep -v '/' | \
      grep -v '^_' | \
      grep -v '^\(all\|clean\|install\|test\|help\|depend\|edit_cache\|rebuild_cache\)$'
    return 0
  fi

  if [[ -n "$builddir" && -f "$builddir/Makefile" && -n ${commands[make]} ]]; then
    make -C "$builddir" help 2>/dev/null | \
      sed -n 's/^\([A-Za-z0-9_-][A-Za-z0-9_-]*\):.*/\1/p' | \
      grep -v '^\(all\|clean\|install\|test\|help\|depend\|edit_cache\|rebuild_cache\)$'
    return 0
  fi

  if [[ -n ${commands[cmake]} && -n "$preset" ]]; then
    cmake --build --preset "$preset" --target help 2>/dev/null | \
      sed -n 's/^\([A-Za-z0-9_-][A-Za-z0-9_-]*\):.*/\1/p' | \
      grep -v '^\(all\|clean\|install\|test\|help\|depend\|edit_cache\|rebuild_cache\)$'
    return 0
  fi

  if [[ -n "$builddir" && -n ${commands[cmake]} ]]; then
    cmake --build "$builddir" --target help 2>/dev/null | \
      sed -n 's/^\([A-Za-z0-9_-][A-Za-z0-9_-]*\):.*/\1/p' | \
      grep -v '^\(all\|clean\|install\|test\|help\|depend\|edit_cache\|rebuild_cache\)$'
  fi
}

_cmc__resolve_target_path() {
  local preset="$1"
  local target="$2"
  local info builddir config
  info="$(_cmc__build_info "$preset")" || return 1
  builddir="${info%%|*}"
  config="${info#*|}"
  if [[ -z "$builddir" ]]; then
    return 1
  fi

  local cand
  if [[ -n "$config" ]]; then
    cand="$builddir/$config/$target/$target"
    [[ -x "$cand" ]] && { print -r -- "$cand"; return 0; }
    cand="$builddir/$config/$target"
    [[ -x "$cand" ]] && { print -r -- "$cand"; return 0; }
    cand="$builddir/$config/$target.app/Contents/MacOS/$target"
    [[ -x "$cand" ]] && { print -r -- "$cand"; return 0; }
  fi

  cand="$builddir/$target/$target"
  [[ -x "$cand" ]] && { print -r -- "$cand"; return 0; }
  cand="$builddir/$target"
  [[ -x "$cand" ]] && { print -r -- "$cand"; return 0; }
  cand="$builddir/$target.app/Contents/MacOS/$target"
  [[ -x "$cand" ]] && { print -r -- "$cand"; return 0; }

  return 1
}

_cmc() {
  local preset="$1"
  if [[ -z "$preset" ]]; then
    print -u2 "usage: _cmc <configure-preset>"
    return 1
  fi
  preset="$(_cmc__resolve_preset configure "$preset")" || {
    print -u2 "cmake configure: unknown preset '$1'"
    return 1
  }
  cmake --preset "$preset"
}

_cmb() {
  local preset="$1"
  local target="$2"
  if [[ -z "$preset" ]]; then
    print -u2 "usage: _cmb <build-preset> [target] [-- build-args]"
    return 1
  fi
  preset="$(_cmc__resolve_preset build "$preset")" || {
    print -u2 "cmake build: unknown preset '$1'"
    return 1
  }

  if [[ -n "$target" ]]; then
    target="$(_cmc__resolve_target "$preset" "$target")" || {
      print -u2 "cmake build: unknown target '$2'"
      return 1
    }
    if (( $# > 2 )); then
      cmake --build --preset "$preset" --target "$target" -- "${@:3}"
    else
      cmake --build --preset "$preset" --target "$target"
    fi
    return $?
  fi

  if (( $# > 1 )); then
    cmake --build --preset "$preset" -- "${@:2}"
  else
    cmake --build --preset "$preset"
  fi
}

_cmr() {
  local preset="$1"
  local target="$2"
  if [[ -z "$preset" || -z "$target" ]]; then
    print -u2 "usage: _cmr <build-preset> <target> [args...]"
    return 1
  fi
  preset="$(_cmc__resolve_preset build "$preset")" || {
    print -u2 "cmake run: unknown preset '$1'"
    return 1
  }
  target="$(_cmc__resolve_target "$preset" "$target")" || {
    print -u2 "cmake run: unknown target '$2'"
    return 1
  }

  local exe
  exe="$(_cmc__resolve_target_path "$preset" "$target")" || {
    print -u2 "cmake run: cannot find executable for target '$target'"
    return 1
  }

  shift 2
  "$exe" "$@"
}

_cmbr() {
  local preset="$1"
  local target="$2"
  if [[ -z "$preset" || -z "$target" ]]; then
    print -u2 "usage: _cmbr <build-preset> <target> [args...]"
    return 1
  fi
  preset="$(_cmc__resolve_preset build "$preset")" || {
    print -u2 "cmake build/run: unknown preset '$1'"
    return 1
  }
  target="$(_cmc__resolve_target "$preset" "$target")" || {
    print -u2 "cmake build/run: unknown target '$2'"
    return 1
  }

  _cmb "$preset" "$target" || return $?
  shift 2
  _cmr "$preset" "$target" "$@"
}

_cmc_complete() {
  local state
  _arguments '1:preset:->presets' && return 0
  case "$state" in
    presets)
      local -a presets matches
      presets=(${(f)"$(_cmc__list_presets configure)"})
      matches=(${(f)"$(_cmc__fuzzy_filter "$PREFIX" "${presets[@]}")"})
      if (( ${#matches[@]} > 0 )); then
        _describe 'configure preset' matches
      fi
      return 0
      ;;
  esac
}

_cmb_complete() {
  local state
  _arguments '1:preset:->presets' '2:target:->targets' '*::args:->args' && return 0
  case "$state" in
    presets)
      local -a presets matches
      presets=(${(f)"$(_cmc__list_presets build)"})
      matches=(${(f)"$(_cmc__fuzzy_filter "$PREFIX" "${presets[@]}")"})
      if (( ${#matches[@]} > 0 )); then
        _describe 'build preset' matches
      fi
      return 0
      ;;
    targets)
      local preset
      preset="$(_cmc__resolve_preset build "$words[2]")" || return 1
      local -a targets matches
      targets=(${(f)"$(_cmc__list_targets "$preset")"})
      matches=(${(f)"$(_cmc__fuzzy_filter "$PREFIX" "${targets[@]}")"})
      if (( ${#matches[@]} > 0 )); then
        _describe 'build target' matches
      fi
      return 0
      ;;
    args)
      return 0
      ;;
  esac
}

_cmr_complete() {
  local state:args:->args' && return 0
  case "$state" in
    presets)
      local -a presets matches
      presets=(${(f)"$(_cmc__list_presets build)"})
      matches=(${(f)"$(_cmc__fuzzy_filter "$PREFIX" "${presets[@]}")"})
      if (( ${#matches[@]} > 0 )); then
        _describe 'build preset' matches
      fi
      return 0
      ;;
    targets)
      local preset
      preset="$(_cmc__resolve_preset build "$words[2]")" || return 1
      local -a targets matches
      targets=(${(f)"$(_cmc__list_targets "$preset")"})
      matches=(${(f)"$(_cmc__fuzzy_filter "$PREFIX" "${targets[@]}")"})
      if (( ${#matches[@]} > 0 )); then
        _describe 'build target' matches
      fi
      return 0
      ;;
    args)
      _files
      return 0_describe 'build target' matches
      fi:args:->args' && return 0
  case "$state" in
    presets)
      local -a presets matches
      presets=(${(f)"$(_cmc__list_presets build)"})
      matches=(${(f)"$(_cmc__fuzzy_filter "$PREFIX" "${presets[@]}")"})
      if (( ${#matches[@]} > 0 )); then
        _describe 'build preset' matches
      fi
      return 0
      ;;
    targets)
      local preset
      preset="$(_cmc__resolve_preset build "$words[2]")" || return 1
      local -a targets matches
      targets=(${(f)"$(_cmc__list_targets "$preset")"})
      matches=(${(f)"$(_cmc__fuzzy_filter "$PREFIX" "${targets[@]}")"})
      if (( ${#matches[@]} > 0 )); then
        _describe 'build target' matches
      fi
      return 0
      ;;
    args)
      _files
      return 0cal preset
      preset="$(_cmc__resolve_preset build "$words[2]")" || return 1
      local -a targets matches
      targets=(${(f)"$(_cmc__list_targets "$preset")"})
      matches=(${(f)"$(_cmc__fuzzy_filter "$PREFIX" "${targets[@]}")"})
      if (( ${#matches[@]} > 0 )); then
        _describe 'build target' matches
      fi
      ;;
  esac
}

if (( $+functions[compdef] )); then
  compdef _cmc_complete _cmc
  compdef _cmb_complete _cmb
  compdef _cmr_complete _cmr
  compdef _cmbr_complete _cmbr
fi
