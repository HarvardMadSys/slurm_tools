#!/usr/bin/env bash
# Install slurm_tools commands into ~/.local/bin and prepend that directory to PATH
# in the rc file that matches login $SHELL (bash, zsh, or fish).

set -euo pipefail

TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${HOME}/.local/bin"
MARKER='# slurm_tools: PATH'

usage() {
  echo "usage: $0 [--dry-run]"
  echo "  Symlinks tools to ${DEST} and appends a PATH snippet to your shell rc."
  exit 0
}

DRY=false
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
fi
if [ "${1:-}" = "--dry-run" ]; then
  DRY=true
fi

link_one() {
  local src="$1" dest_name="$2"
  local dest="${DEST}/${dest_name}"
  if $DRY; then
    echo "ln -sf $(printf '%q' "$src") $(printf '%q' "$dest")"
  else
    ln -sf "$src" "$dest"
  fi
}

append_path_bash_zsh() {
  local rc="$1"
  if [ ! -f "$rc" ] && ! $DRY; then
    touch "$rc"
  fi
  if $DRY; then
    echo "ensure PATH block in $(printf '%q' "$rc")"
    return 0
  fi
  if [ -f "$rc" ] && grep -qF "$MARKER" "$rc"; then
    echo "PATH block already present in $rc"
    return 0
  fi
  {
    echo ""
    echo "$MARKER"
    echo 'case ":${PATH}:" in'
    echo '  *:"${HOME}/.local/bin":*) ;;'
    echo '  *) export PATH="${HOME}/.local/bin:${PATH}" ;;'
    echo 'esac'
  } >>"$rc"
  echo "Appended PATH block to $rc"
}

append_path_fish() {
  local rc="${HOME}/.config/fish/config.fish"
  if ! $DRY; then
    mkdir -p "$(dirname "$rc")"
    touch "$rc"
  fi
  if $DRY; then
    echo "ensure fish PATH in $(printf '%q' "$rc")"
    return 0
  fi
  if [ -f "$rc" ] && grep -qF "$MARKER" "$rc"; then
    echo "PATH block already present in $rc"
    return 0
  fi
  {
    echo ""
    echo "$MARKER"
    echo 'fish_add_path $HOME/.local/bin'
  } >>"$rc"
  echo "Appended PATH block to $rc"
}

if $DRY; then
  echo "[dry-run] would install symlink commands under ${DEST}"
else
  mkdir -p "$DEST"
fi

if ! $DRY; then
  chmod +x "${TOOL_ROOT}/best_partition.py" "${TOOL_ROOT}/print_alloc.py" "${TOOL_ROOT}/dep/node_monitor.py" "${TOOL_ROOT}/alloc.sh"
fi

link_one "${TOOL_ROOT}/best_partition.py" "best_partition"
link_one "${TOOL_ROOT}/print_alloc.py" "print_alloc"
link_one "${TOOL_ROOT}/dep/node_monitor.py" "node_monitor"
link_one "${TOOL_ROOT}/alloc.sh" "slurm-alloc"

shell_base="$(basename "${SHELL:-bash}")"

case "$shell_base" in
  zsh)
    append_path_bash_zsh "${HOME}/.zshrc"
    ;;
  bash)
    if [ "$(uname -s)" = Darwin ]; then
      if [ -f "${HOME}/.bash_profile" ]; then
        append_path_bash_zsh "${HOME}/.bash_profile"
      fi
      if [ -f "${HOME}/.bashrc" ]; then
        append_path_bash_zsh "${HOME}/.bashrc"
      elif ! $DRY; then
        append_path_bash_zsh "${HOME}/.bashrc"
      fi
    else
      append_path_bash_zsh "${HOME}/.bashrc"
    fi
    ;;
  fish)
    append_path_fish
    ;;
  *)
    echo "Default shell '${shell_base}' not handled; adding PATH to ~/.profile if present."
    if [ -f "${HOME}/.profile" ]; then
      append_path_bash_zsh "${HOME}/.profile"
    else
      append_path_bash_zsh "${HOME}/.bashrc"
    fi
    ;;
esac

if $DRY; then
  echo "[dry-run] done."
else
  echo "Installed: best_partition, print_alloc, node_monitor, slurm-alloc → $DEST"
  echo "Restart the shell or: source your rc file"
fi
