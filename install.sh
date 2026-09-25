#!/usr/bin/env bash
# Plans all changes, shows them, then applies the ones you accept. Safe to re-run.
set -euo pipefail

usage() {
  cat << 'EOF'
usage: install.sh [--yes] [--dry-run] [--no-deps] [--no-chsh]
  --yes      apply all planned changes without prompting
  --dry-run  show planned changes and exit
  --no-deps  don't plan package installs (or Homebrew on macOS)
  --no-chsh  don't plan changing the login shell to zsh
EOF
}

CONFIRM=ask
DRY_RUN=no
INSTALL_DEPS=yes
CHANGE_SHELL=yes
for arg in "$@"; do
  case "$arg" in
    --yes) CONFIRM=all ;;
    --dry-run) DRY_RUN=yes ;;
    --no-deps) INSTALL_DEPS=no ;;
    --no-chsh) CHANGE_SHELL=no ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
OS="$(uname -s)"

case "$OS" in
  MINGW* | MSYS* | CYGWIN*) echo "error: on Windows use install.ps1 (it also sets up Git Bash)" >&2; exit 1 ;;
esac

# Home-relative form so rc files stay valid if $HOME moves
tilde() {
  case "$1" in
    "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

REPO_T="$(tilde "$REPO")"
case "$REPO_T" in
  *[[:space:]]*) echo "error: repo path must not contain whitespace: $REPO" >&2; exit 1 ;;
esac

# Plan: parallel arrays, since bash 3.2 (stock macOS) has no associative arrays
STEP_DESC=()
STEP_FN=()
STEP_A1=()
STEP_A2=()
DONE=()
NOTES=()

plan() {
  STEP_DESC+=("$1")
  STEP_FN+=("$2")
  STEP_A1+=("${3:-}")
  STEP_A2+=("${4:-}")
}

done_item() {
  DONE+=("$1")
}

note() {
  NOTES+=("$1")
}

# ---- actions (only run for accepted steps)

do_line() {
  local file="$1" line="$2"
  if [[ -f "$file" ]] && grep -qxF -- "$line" "$file"; then
    return
  fi
  if [[ -s "$file" ]]; then
    printf '\n%s\n' "$line" >> "$file"
  else
    printf '%s\n' "$line" >> "$file"
  fi
}

do_symlink() {
  ln -s "$1" "$2"
}

do_clone() {
  mkdir -p "$(dirname "$2")"
  git clone --quiet --depth=1 "$1" "$2"
}

do_copy() {
  mkdir -p "$(dirname "$2")"
  cp "$1" "$2"
}

do_git_include() {
  local tmp
  tmp="$(mktemp)"
  {
    printf '[include]\n\tpath = %s\n' "$1"
    if [[ -f "$HOME/.gitconfig" ]]; then
      cat "$HOME/.gitconfig"
    fi
  } > "$tmp"
  # cat rather than mv to preserve a symlinked ~/.gitconfig
  cat "$tmp" > "$HOME/.gitconfig"
  rm "$tmp"
}

do_submodules() {
  git -C "$REPO" submodule sync --quiet
  git -C "$REPO" submodule update --init --quiet
}

do_homebrew() {
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$("$BREW" shellenv bash)"
}

do_packages() {
  case "$PLATFORM" in
    macos)
      if ! command -v brew > /dev/null; then
        echo "skipped: Homebrew not installed"
        return
      fi
      brew install "${MISSING[@]}"
      ;;
    arch) as_root pacman "$PACMAN_OP" --needed --noconfirm "${MISSING[@]}" ;;
    debian)
      as_root apt-get update
      as_root apt-get install -y "${MISSING[@]}"
      ;;
  esac
}

# First zsh in /etc/shells: chsh rejects anything else, and the PATH lookup may give an
# alias like /usr/sbin/zsh on merged-usr distros or a Homebrew zsh that brew upgrades can break
login_zsh() {
  local shell
  while read -r shell; do
    if [[ "$(basename "$shell")" == zsh && -x "$shell" ]]; then
      echo "$shell"
      return
    fi
  done < <(grep -v '^#' /etc/shells 2> /dev/null || true)
}

do_chsh() {
  local zsh_path
  zsh_path="$(login_zsh)"
  if [[ -z "$zsh_path" ]]; then
    echo "skipped: no zsh listed in /etc/shells"
  elif ! command -v chsh > /dev/null; then
    echo "skipped: chsh not available"
  elif [[ "$1" == sudo ]]; then
    as_root chsh -s "$zsh_path" "$(id -un)"
  else
    chsh -s "$zsh_path"
  fi
}

as_root() {
  if [[ "$EUID" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

# ---- planning helpers (read-only)

plan_line() {
  local file="$1" line="$2"
  if [[ -f "$file" ]] && grep -qxF -- "$line" "$file"; then
    done_item "$(tilde "$file") has: $line"
  else
    plan "Append to $(tilde "$file"): $line" do_line "$file" "$line"
  fi
}

plan_symlink() {
  local target="$1" link="$2"
  if [[ -L "$link" && "$(readlink "$link")" == "$target" ]]; then
    done_item "$(tilde "$link") -> $(tilde "$target")"
  elif [[ -e "$link" || -L "$link" ]]; then
    note "$(tilde "$link") exists and is not a link to $(tilde "$target"); move it aside and re-run"
  else
    plan "Symlink $(tilde "$link") -> $(tilde "$target")" do_symlink "$target" "$link"
  fi
}

plan_clone() {
  local url="$1" dir="$2"
  if [[ -d "$dir" ]]; then
    done_item "$(tilde "$dir") exists"
  else
    plan "git clone $url $(tilde "$dir")" do_clone "$url" "$dir"
  fi
}

plan_copy() {
  local src="$1" dst="$2"
  if cmp -s "$src" "$dst"; then
    done_item "$(tilde "$dst") up to date"
  elif [[ -e "$dst" ]]; then
    plan "Overwrite $(tilde "$dst") with $(tilde "$src")" do_copy "$src" "$dst"
  else
    plan "Copy $(tilde "$src") -> $(tilde "$dst")" do_copy "$src" "$dst"
  fi
}

platform() {
  if [[ "$OS" == Darwin ]]; then
    echo macos
    return
  fi
  local id="" like="" token
  if [[ -f /etc/os-release ]]; then
    id="$(. /etc/os-release && echo "${ID:-}")"
    like="$(. /etc/os-release && echo "${ID_LIKE:-}")"
  fi
  # SteamOS reports ID_LIKE=arch but has a read-only root
  if [[ "$id" == steamos ]]; then
    echo steamos
    return
  fi
  for token in $id $like; do
    case "$token" in
      arch | debian) echo "$token"; return ;;
    esac
  done
  echo unknown
}

is_installed() {
  case "$PLATFORM" in
    macos) command -v brew > /dev/null && brew list --formula --versions "$1" > /dev/null ;;
    # -T resolves provides, e.g. gvim satisfies vim
    arch) pacman -T "$1" > /dev/null 2>&1 ;;
    debian) [[ "$(dpkg-query -W -f='${Status}' "$1" 2> /dev/null || true)" == "install ok installed" ]] ;;
  esac
}

# ---- plan

PLATFORM="$(platform)"
PKGS_COMMON=(cmake ripgrep jq htop tmux mc fzf zoxide)
case "$PLATFORM" in
  # git, vim and zsh ship with macOS
  macos) PKGS=("${PKGS_COMMON[@]}" coreutils python ninja fd) ;;
  arch) PKGS=("${PKGS_COMMON[@]}" zsh git vim python ninja fd) ;;
  debian) PKGS=("${PKGS_COMMON[@]}" zsh git vim python3 ninja-build fd-find) ;;
  *) PKGS=() ;;
esac

# -Sy without -u is an unsupported partial upgrade, so only sync (with full upgrade) when there is no db
PACMAN_OP=-S
if [[ "$PLATFORM" == arch ]] && ! compgen -G '/var/lib/pacman/sync/*.db' > /dev/null; then
  PACMAN_OP=-Syu
fi

MISSING=()
ZSH_PLANNED=no
if [[ "$INSTALL_DEPS" == no ]]; then
  note "packages not checked (--no-deps)"
elif [[ "$PLATFORM" == steamos ]]; then
  note "packages not installed on SteamOS (read-only root)"
elif [[ "$PLATFORM" == unknown ]]; then
  note "packages not installed: unsupported platform"
else
  if [[ "$PLATFORM" == macos ]]; then
    if [[ "$(uname -m)" == arm64 ]]; then
      BREW=/opt/homebrew/bin/brew
    else
      BREW=/usr/local/bin/brew
    fi
    if [[ -x "$BREW" ]]; then
      eval "$("$BREW" shellenv bash)"
      done_item "Homebrew at $BREW"
    else
      plan "Install Homebrew to $(dirname "$(dirname "$BREW")") (official installer, asks for sudo)" do_homebrew
    fi
  fi

  for pkg in "${PKGS[@]}"; do
    if ! is_installed "$pkg"; then
      MISSING+=("$pkg")
    fi
  done

  # Guarded: bash 3.2 treats "${empty[@]}" as unbound under set -u
  if [[ "${#MISSING[@]}" -eq 0 ]]; then
    done_item "packages: ${PKGS[*]}"
  else
    case "$PLATFORM" in
      macos) cmd="brew install" ;;
      arch) cmd="sudo pacman $PACMAN_OP --needed --noconfirm" ;;
      debian) cmd="sudo apt-get update && sudo apt-get install -y" ;;
    esac
    if [[ "$EUID" -eq 0 ]]; then
      cmd="${cmd//sudo /}"
    fi
    if [[ "$PACMAN_OP" == -Syu ]]; then
      plan "$cmd ${MISSING[*]} (no package db yet: syncs and upgrades the whole system)" do_packages
    else
      plan "$cmd ${MISSING[*]}" do_packages
    fi
    case " ${MISSING[*]} " in
      *" zsh "*) ZSH_PLANNED=yes ;;
    esac
  fi
fi

if command -v zsh > /dev/null || [[ "$ZSH_PLANNED" == yes ]]; then
  plan_clone https://github.com/ohmyzsh/ohmyzsh.git "$HOME/.oh-my-zsh"
  plan_clone https://github.com/zsh-users/zsh-completions.git "$HOME/.oh-my-zsh/custom/plugins/zsh-completions"
  plan_line "$HOME/.zshrc" "source $REPO_T/zsh/zshrc"
else
  note "zsh config skipped: zsh not installed"
fi

if [[ "$OS" == Darwin ]]; then
  plan_line "$HOME/.bash_profile" "source $REPO_T/bash/kayru_common.sh"
  plan_line "$HOME/.bash_profile" "source $REPO_T/bash/dir_colors.sh"
else
  plan_line "$HOME/.bashrc" "source $REPO_T/bash/kayru_common.sh"
  plan_line "$HOME/.bashrc" "source $REPO_T/bash/dir_colors.sh"
fi

# Prepended so settings later in ~/.gitconfig override the shared ones
GIT_INCLUDE="$REPO_T/git/gitconfig"
if command -v git > /dev/null; then
  existing_includes="$(git config --global --get-all include.path || true)"
else
  existing_includes=""
fi
if grep -qxF -- "$GIT_INCLUDE" <<< "$existing_includes"; then
  done_item "~/.gitconfig includes $GIT_INCLUDE"
else
  plan "Prepend to ~/.gitconfig: [include] path = $GIT_INCLUDE" do_git_include "$GIT_INCLUDE"
fi

submodules_ready=yes
if ! command -v git > /dev/null; then
  submodules_ready=no
else
  submodule_status="$(git -C "$REPO" submodule status)"
  if grep -q '^[-+U]' <<< "$submodule_status"; then
    submodules_ready=no
  fi
  while read -r key url; do
    name="${key#submodule.}"
    name="${name%.url}"
    if [[ "$(git -C "$REPO" config --get "submodule.$name.url" || true)" != "$url" ]]; then
      submodules_ready=no
    fi
  done < <(git -C "$REPO" config -f .gitmodules --get-regexp '^submodule\..*\.url$')
fi
if [[ "$submodules_ready" == yes ]]; then
  done_item "vim plugin submodules checked out"
else
  plan "Check out vim plugin submodules in $REPO_T (git submodule sync + update --init)" do_submodules
fi
plan_symlink "$REPO/vim" "$HOME/.vim"
plan_line "$HOME/.vimrc" "source ~/.vim/kayru.vim"

if [[ "$OS" == Darwin ]]; then
  plan_copy "$REPO/macos/DefaultKeyBinding.dict" "$HOME/Library/KeyBindings/DefaultKeyBinding.dict"
  plan_copy "$REPO/macos/Kayru.dvtcolortheme" "$HOME/Library/Developer/Xcode/UserData/FontAndColorThemes/Kayru.dvtcolortheme"
fi

if [[ "$CHANGE_SHELL" == no ]]; then
  note "login shell not checked (--no-chsh)"
else
  zsh_path="$(login_zsh)"
  if [[ "$OS" == Darwin ]]; then
    current_shell="$(dscl . -read "/Users/$(id -un)" UserShell | awk '{print $2}')"
  else
    current_shell="$(getent passwd "$(id -un)" | cut -d: -f7)"
  fi
  if [[ "$(basename "$current_shell")" == zsh ]]; then
    done_item "login shell is $current_shell"
  elif ! command -v chsh > /dev/null && [[ "${#MISSING[@]}" -eq 0 ]]; then
    note "login shell unchanged: chsh not available"
  elif [[ -z "$zsh_path" && "$ZSH_PLANNED" == no ]]; then
    note "login shell unchanged: no zsh listed in /etc/shells"
  else
    # chsh authenticates with the account password; cloud images (e.g. EC2 ubuntu) lock it
    password_state=""
    if [[ "$OS" != Darwin ]]; then
      password_state="$(passwd -S "$(id -un)" 2> /dev/null | awk '{print $2}' || true)"
    fi
    if [[ "$password_state" == L || "$password_state" == NP ]]; then
      plan "Change login shell from $current_shell to ${zsh_path:-zsh} (sudo chsh: account has no usable password)" do_chsh sudo
    else
      plan "Change login shell from $current_shell to ${zsh_path:-zsh} (chsh, asks for password)" do_chsh
    fi
  fi
fi

# ---- show plan

echo "Platform: $PLATFORM"
if [[ "${#DONE[@]}" -gt 0 ]]; then
  echo
  echo "Already done:"
  for item in "${DONE[@]}"; do
    echo "  $item"
  done
fi
if [[ "${#NOTES[@]}" -gt 0 ]]; then
  echo
  echo "Notes:"
  for item in "${NOTES[@]}"; do
    echo "  $item"
  done
fi
echo
if [[ "${#STEP_DESC[@]}" -eq 0 ]]; then
  echo "Nothing to do."
  exit 0
fi
echo "Planned changes:"
for i in "${!STEP_DESC[@]}"; do
  printf '  %2d. %s\n' "$((i + 1))" "${STEP_DESC[$i]}"
done
echo

if [[ "$DRY_RUN" == yes ]]; then
  exit 0
fi

# ---- confirm

abort_on_eof() {
  echo
  echo "aborted: end of input" >&2
  exit 1
}

if [[ "$CONFIRM" == ask ]]; then
  if [[ ! -t 0 ]]; then
    echo "error: stdin is not a terminal; pass --yes to apply without prompting" >&2
    exit 1
  fi
  while true; do
    read -r -p "Apply: [a]ll, [o]ne by one, [q]uit? " answer || abort_on_eof
    case "$answer" in
      a | A) CONFIRM=all; break ;;
      o | O) CONFIRM=each; break ;;
      q | Q) exit 0 ;;
    esac
  done
fi

# ---- apply

CURRENT_STEP=""
# errtrace: report failures inside step functions too
set -E
trap 'echo "error: failed: $CURRENT_STEP" >&2' ERR

for i in "${!STEP_DESC[@]}"; do
  desc="${STEP_DESC[$i]}"
  if [[ "$CONFIRM" == each ]]; then
    while true; do
      read -r -p "$((i + 1)). $desc  [y]es, [n]o, [a]ll remaining, [q]uit? " answer || abort_on_eof
      case "$answer" in
        y | Y) break ;;
        n | N) continue 2 ;;
        a | A) CONFIRM=all; break ;;
        q | Q) exit 0 ;;
      esac
    done
  fi
  echo "==> $desc"
  CURRENT_STEP="$desc"
  "${STEP_FN[$i]}" "${STEP_A1[$i]}" "${STEP_A2[$i]}"
done
echo "Done."
