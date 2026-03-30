# Capture plugin directory at source time
typeset -g _CMC_PLUGIN_DIR="${${(%):-%x}:A:h}"

# Helper: Find directory containing CMakePresets.json
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

# Helper: Fuzzy filter items by query
_cmc__fuzzy_filter() {
  local query="$1"
  shift
  local -a items=("$@")
  
  [[ -z "$query" ]] && { printf '%s\n' "${items[@]}"; return 0; }
  
  local q="${query:l}" item s c i ok
  for item in "${items[@]}"; do
    s="${item:l}"
    ok=1
    for ((i=1; i<=${#q}; i++)); do
      c="${q[i]}"
      [[ "$s" == *"$c"* ]] && s="${s#*${c}}" || { ok=0; break; }
    done
    (( ok )) && print -r -- "$item"
  done
}

# Helper: Pick single match from fuzzy filter
_cmc__fuzzy_pick() {
  local -a matches=(${(f)"$(_cmc__fuzzy_filter "$@")"})
  (( ${#matches[@]} == 1 )) && print -r -- "$matches[1]"
}

# Helper: Resolve preset name (exact match or fuzzy)
_cmc__resolve_preset() {
  local kind="$1" input="$2"
  [[ -z "$input" ]] && return 1
  
  local -a presets=(${(f)"$(_cmc__list_presets "$kind")"})
  local p
  for p in "${presets[@]}"; do
    [[ "$p" == "$input" ]] && { print -r -- "$input"; return 0; }
  done
  _cmc__fuzzy_pick "$input" "${presets[@]}"
}

# Helper: Resolve target name (exact match or fuzzy)
_cmc__resolve_target() {
  local preset="$1" input="$2"
  [[ -z "$input" ]] && return 1
  
  local -a targets=(${(f)"$(_cmc__list_targets "$preset")"})
  local t
  for t in "${targets[@]}"; do
    [[ "$t" == "$input" ]] && { print -r -- "$input"; return 0; }
  done
  _cmc__fuzzy_pick "$input" "${targets[@]}"
}

# List configure or build presets
_cmc__list_presets() {
  local kind="$1" dir
  dir="$(_cmc__find_presets_dir)" || return 0
  python3 "$_CMC_PLUGIN_DIR/list_presets.py" "$dir" "$kind"
}

# Get build directory and configuration for preset
_cmc__build_info() {
  local preset="$1" dir
  dir="$(_cmc__find_presets_dir)" || return 1
  python3 "$_CMC_PLUGIN_DIR/build_info.py" "$dir" "$preset"
}

# List executable targets for a preset (for run commands)
_cmc__list_executable_targets() {
  local preset="$1" info builddir
  info="$(_cmc__build_info "$preset")" || return 0
  builddir="${info%%|*}"
  [[ -n "$builddir" && -f "$builddir/build.ninja" ]] || {
    _cmc__list_targets "$preset"
    return
  }
  awk '
    /EXECUTABLE_LINKER/ { sub(/^build /, ""); sub(/:.*/, ""); exe[$0]=1 }
    /: phony / {
      line=$0; sub(/^build /, "", line)
      n=index(line, ": phony "); name=substr(line,1,n-1); path=substr(line,n+8)
      if (path in exe) print name
    }
  ' "$builddir/build.ninja" | \
    grep -vE '^\.|^CMakeFiles|/|^_|^(all|clean|install|test|help|depend|edit_cache|rebuild_cache)$'
}

# List available build targets for a preset
_cmc__list_targets() {
  local preset="$1" info builddir
  info="$(_cmc__build_info "$preset")"
  builddir="${info%%|*}"
  
  # Try ninja first
  if [[ -n "$builddir" && -f "$builddir/build.ninja" && -n ${commands[ninja]} ]]; then
    ninja -C "$builddir" -t targets 2>/dev/null | \
      sed -n 's/: phony$//p' | \
      grep -vE '^\.|^CMakeFiles|/|^_|^(all|clean|install|test|help|depend|edit_cache|rebuild_cache)$'
    return 0
  fi
  
  # Try make
  if [[ -n "$builddir" && -f "$builddir/Makefile" && -n ${commands[make]} ]]; then
    make -C "$builddir" help 2>/dev/null | \
      sed -n 's/^\.\.\.  *\([A-Za-z0-9_-][A-Za-z0-9_-]*\).*/\1/p' | \
      grep -vE '^(all|clean|install|test|help|depend|edit_cache|rebuild_cache)$'
    return 0
  fi
  
  # Fallback to cmake with preset
  if [[ -n ${commands[cmake]} && -n "$preset" ]]; then
    cmake --build --preset "$preset" --target help 2>/dev/null | \
      sed -n -e 's/^\([^:][^:]*\):.*/\1/p' -e 's/^\.\.\.  *\([A-Za-z0-9_-][A-Za-z0-9_-]*\).*/\1/p' | \
      grep -vE '^\.|^CMakeFiles|/|^_|^(all|clean|install|test|help|depend|edit_cache|rebuild_cache)$'
    return 0
  fi

  # Last resort: cmake with build directory
  if [[ -n "$builddir" && -n ${commands[cmake]} ]]; then
    cmake --build "$builddir" --target help 2>/dev/null | \
      sed -n -e 's/^\([^:][^:]*\):.*/\1/p' -e 's/^\.\.\.  *\([A-Za-z0-9_-][A-Za-z0-9_-]*\).*/\1/p' | \
      grep -vE '^\.|^CMakeFiles|/|^_|^(all|clean|install|test|help|depend|edit_cache|rebuild_cache)$'
  fi
}

# Check if build dir is configured; if not, run the configure step
_cmc__ensure_configured() {
  local preset="$1" info builddir configure_preset
  info="$(_cmc__build_info "$preset")" || return 1
  builddir="${info%%|*}"
  configure_preset="${info##*|}"
  if [[ -z "$builddir" || ! -f "$builddir/CMakeCache.txt" ]]; then
    if [[ -z "$configure_preset" ]]; then
      print -u2 "cmake: cannot determine configure preset for build preset '$preset'"
      return 1
    fi
    print -u2 "cmake: build directory not configured, auto-configuring"
    print -u2 ">> cmake --preset $configure_preset"
    cmake --preset "$configure_preset" || return 1
  fi
}

# Find executable path for a target
_cmc__resolve_target_path() {
  local preset="$1" target="$2" info builddir config
  info="$(_cmc__build_info "$preset")" || return 1
  builddir="${info%%|*}"
  config="${${info#*|}%%|*}"
  [[ -z "$builddir" ]] && return 1

  # Ask ninja for the real output path behind the phony target
  # For multi-config generators (Ninja Multi-Config), use the config-specific
  # ninja file (build-<Config>.ninja) instead of build.ninja which only has the
  # default config.
  if [[ -n ${commands[ninja]} ]]; then
    local ninja_file=""
    if [[ -n "$config" && -f "$builddir/build-${config}.ninja" ]]; then
      ninja_file="$builddir/build-${config}.ninja"
    elif [[ -f "$builddir/build.ninja" ]]; then
      ninja_file="$builddir/build.ninja"
    fi
    if [[ -n "$ninja_file" ]]; then
      local relpath
      relpath="$(sed -n "s/^build ${target}: phony //p" "$ninja_file")"
      if [[ -n "$relpath" ]]; then
        local exe="$builddir/$relpath"
        # Handle macOS .app bundles
        if [[ "$exe" == *.app ]]; then
          exe="$exe/Contents/MacOS/$target"
        fi
        [[ -x "$exe" ]] && { print -r -- "$exe"; return 0; }
      fi
    fi
  fi

  # Static candidates for multi-config generators (e.g. Xcode, VS)
  local -a candidates=()
  if [[ -n "$config" ]]; then
    candidates+=(
      "$builddir/$config/$target"
      "$builddir/$config/$target.app/Contents/MacOS/$target"
    )
  else
    candidates+=(
      "$builddir/$target"
      "$builddir/$target.app/Contents/MacOS/$target"
    )
  fi

  local cand
  for cand in "${candidates[@]}"; do
    [[ -x "$cand" ]] && { print -r -- "$cand"; return 0; }
  done
  return 1
}

# Command: Configure CMake project
_cmc() {
  [[ -z "$1" ]] && { print -u2 "usage: _cmc <configure-preset>"; return 1; }
  local preset
  preset="$(_cmc__resolve_preset configure "$1")" || {
    print -u2 "cmake configure: unknown preset '$1'"
    return 1
  }
  print -u2 ">> cmake --preset $preset"
  cmake --preset "$preset"
}

# Command: Build CMake project
_cmb() {
  [[ -z "$1" ]] && { print -u2 "usage: _cmb <build-preset> [target] [-- build-args]"; return 1; }
  local preset target
  preset="$(_cmc__resolve_preset build "$1")" || {
    print -u2 "cmake build: unknown preset '$1'"
    return 1
  }
  _cmc__ensure_configured "$preset" || return 1

  if [[ -n "$2" ]]; then
    target="$(_cmc__resolve_target "$preset" "$2")" || {
      print -u2 "cmake build: unknown target '$2'"
      return 1
    }
    print -u2 ">> cmake --build --preset $preset --target $target ${@:3}"
    cmake --build --preset "$preset" --target "$target" ${@:3}
  else
    print -u2 ">> cmake --build --preset $preset ${@:2}"
    cmake --build --preset "$preset" ${@:2}
  fi
}

# Command: Run target executable
_cmr() {
  [[ -z "$1" || -z "$2" ]] && { print -u2 "usage: _cmr <build-preset> <target> [args...]"; return 1; }
  local preset target exe
  preset="$(_cmc__resolve_preset build "$1")" || {
    print -u2 "cmake run: unknown preset '$1'"
    return 1
  }
  _cmc__ensure_configured "$preset" || return 1
  target="$(_cmc__resolve_target "$preset" "$2")" || {
    print -u2 "cmake run: unknown target '$2'"
    return 1
  }
  exe="$(_cmc__resolve_target_path "$preset" "$target")" || {
    print -u2 "cmake run: cannot find executable for target '$target'"
    return 1
  }
  print -u2 ">> $exe ${@:3}"
  "$exe" "${@:3}"
}

# Command: Build and run target
_cmbr() {
  [[ -z "$1" || -z "$2" ]] && { print -u2 "usage: _cmbr <build-preset> <target> [args...]"; return 1; }
  local preset target
  preset="$(_cmc__resolve_preset build "$1")" || {
    print -u2 "cmake build/run: unknown preset '$1'"
    return 1
  }
  _cmc__ensure_configured "$preset" || return 1
  target="$(_cmc__resolve_target "$preset" "$2")" || {
    print -u2 "cmake build/run: unknown target '$2'"
    return 1
  }
  _cmb "$preset" "$target" && _cmr "$preset" "$target" "${@:3}"
}

# Completion functions
_cmc_complete() {
  local state
  _arguments '1:preset:->presets' && return 0
  case "$state" in
    presets)
      local -a presets=(${(f)"$(_cmc__list_presets configure)"})
      local -a matches=(${(f)"$(_cmc__fuzzy_filter "$PREFIX" "${presets[@]}")"})
      (( ${#matches[@]} > 0 )) && _describe 'configure preset' matches
      ;;
  esac
}

_cmb_complete() {
  local state
  _arguments '1:preset:->presets' '2:target:->targets' '*::args:->args' && return 0
  case "$state" in
    presets)
      local -a presets=(${(f)"$(_cmc__list_presets build)"})
      local -a matches=(${(f)"$(_cmc__fuzzy_filter "$PREFIX" "${presets[@]}")"})
      (( ${#matches[@]} > 0 )) && _describe 'build preset' matches
      ;;
    targets)
      local preset
      preset="$(_cmc__resolve_preset build "$words[2]")" || return 1
      local -a targets=(${(f)"$(_cmc__list_targets "$preset")"})
      local -a matches=(${(f)"$(_cmc__fuzzy_filter "$PREFIX" "${targets[@]}")"})
      (( ${#matches[@]} > 0 )) && _describe 'build target' matches
      ;;
  esac
}

_cmr_complete() {
  local state
  _arguments '1:preset:->presets' '2:target:->targets' '*::args:->args' && return 0
  case "$state" in
    presets)
      local -a presets=(${(f)"$(_cmc__list_presets build)"})
      local -a matches=(${(f)"$(_cmc__fuzzy_filter "$PREFIX" "${presets[@]}")"})
      (( ${#matches[@]} > 0 )) && _describe 'build preset' matches
      ;;
    targets)
      local preset
      preset="$(_cmc__resolve_preset build "$words[2]")" || return 1
      local -a targets=(${(f)"$(_cmc__list_executable_targets "$preset")"})
      local -a matches=(${(f)"$(_cmc__fuzzy_filter "$PREFIX" "${targets[@]}")"})
      (( ${#matches[@]} > 0 )) && _describe 'executable target' matches
      ;;
    args)
      _files
      ;;
  esac
}

# Register completions
if (( $+functions[compdef] )); then
  compdef _cmc_complete _cmc
  compdef _cmb_complete _cmb
  compdef _cmr_complete _cmr
  compdef _cmr_complete _cmbr
fi
