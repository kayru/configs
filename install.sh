#!/usr/bin/env bash
# Idempotent: safe to re-run after pulling.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
OS="$(uname -s)"

# Home-relative form so rc files stay valid if $HOME moves
tilde() {
  case "$1" in
    "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

ensure_line() {
  local file="$1" line="$2"
  if [[ -f "$file" ]] && grep -qxF -- "$line" "$file"; then
    echo "ok       $file: $line"
    return
  fi
  if [[ -s "$file" ]]; then
    printf '\n%s\n' "$line" >> "$file"
  else
    printf '%s\n' "$line" >> "$file"
  fi
  echo "added    $file: $line"
}

ensure_symlink() {
  local target="$1" link="$2"
  if [[ -L "$link" && "$(readlink "$link")" == "$target" ]]; then
    echo "ok       $link -> $target"
  elif [[ -e "$link" || -L "$link" ]]; then
    echo "SKIPPED  $link exists and is not a link to $target; move it aside and re-run"
  else
    ln -s "$target" "$link"
    echo "linked   $link -> $target"
  fi
}

ensure_clone() {
  local url="$1" dir="$2"
  if [[ -d "$dir" ]]; then
    echo "ok       $dir"
  else
    mkdir -p "$(dirname "$dir")"
    git clone --quiet --depth=1 "$url" "$dir"
    echo "cloned   $url -> $dir"
  fi
}

ensure_copy() {
  local src="$1" dst="$2"
  if cmp -s "$src" "$dst"; then
    echo "ok       $dst"
  else
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    echo "copied   $dst"
  fi
}

REPO_T="$(tilde "$REPO")"
case "$REPO_T" in
  *[[:space:]]*) echo "error: repo path must not contain whitespace: $REPO" >&2; exit 1 ;;
esac

echo "== zsh"
if command -v zsh > /dev/null; then
  ensure_clone https://github.com/ohmyzsh/ohmyzsh.git "$HOME/.oh-my-zsh"
  ensure_clone https://github.com/zsh-users/zsh-completions.git "$HOME/.oh-my-zsh/custom/plugins/zsh-completions"
  ensure_line "$HOME/.zshrc" "source $REPO_T/zsh/zshrc"
else
  echo "SKIPPED  zsh not installed"
fi

echo "== bash"
if [[ "$OS" == Darwin ]]; then
  BASHRC="$HOME/.bash_profile"
else
  BASHRC="$HOME/.bashrc"
fi
ensure_line "$BASHRC" "source $REPO_T/bash/kayru_common.sh"
ensure_line "$BASHRC" "source $REPO_T/bash/dir_colors.sh"

echo "== git"
# Prepended so settings later in ~/.gitconfig override the shared ones
GIT_INCLUDE="$REPO_T/git/gitconfig"
existing_includes="$(git config --global --get-all include.path || true)"
if grep -qxF -- "$GIT_INCLUDE" <<< "$existing_includes"; then
  echo "ok       ~/.gitconfig includes $GIT_INCLUDE"
else
  gitconfig_tmp="$(mktemp)"
  {
    printf '[include]\n\tpath = %s\n' "$GIT_INCLUDE"
    if [[ -f "$HOME/.gitconfig" ]]; then
      cat "$HOME/.gitconfig"
    fi
  } > "$gitconfig_tmp"
  # cat rather than mv to preserve a symlinked ~/.gitconfig
  cat "$gitconfig_tmp" > "$HOME/.gitconfig"
  rm "$gitconfig_tmp"
  echo "added    ~/.gitconfig includes $GIT_INCLUDE"
fi

echo "== vim"
git -C "$REPO" submodule sync --quiet
git -C "$REPO" submodule update --init --quiet
echo "ok       submodules"
ensure_symlink "$REPO/vim" "$HOME/.vim"
ensure_line "$HOME/.vimrc" "source ~/.vim/kayru.vim"

if [[ "$OS" == Darwin ]]; then
  echo "== macos"
  ensure_copy "$REPO/macos/DefaultKeyBinding.dict" "$HOME/Library/KeyBindings/DefaultKeyBinding.dict"
  ensure_copy "$REPO/macos/Kayru.dvtcolortheme" "$HOME/Library/Developer/Xcode/UserData/FontAndColorThemes/Kayru.dvtcolortheme"
fi
