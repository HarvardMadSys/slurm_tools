#!/bin/bash

# Install slurm_tools commands into ~/.local/bin and prepend that directory to PATH
# in the rc file that matches login $SHELL (bash, zsh, or fish).
#
# Styling patterned after Homebrew's install script (https://github.com/Homebrew/install).

set -euo pipefail

# Allow `[[ -n "$(command)" ]]`, pipes, etc.
# shellcheck disable=SC2312

abort() {
  printf "%s\n" "$@" >&2
  exit 1
}

if [ -z "${BASH_VERSION:-}" ]; then
  abort "Bash is required to interpret this script."
fi

if [[ -n "${POSIXLY_CORRECT+1}" ]]; then
  abort 'Bash must not run in POSIX mode. Please unset POSIXLY_CORRECT and try again.'
fi

if [[ -n "${CI-}" && -n "${INTERACTIVE-}" ]]; then
  abort "Cannot run force-interactive mode in CI."
fi

if [[ -n "${INTERACTIVE-}" && -n "${NONINTERACTIVE-}" ]]; then
  abort 'Both `$INTERACTIVE` and `$NONINTERACTIVE` are set. Please unset at least one variable and try again.'
fi

if [[ -t 1 ]]; then
  tty_escape() { printf "\033[%sm" "$1"; }
else
  tty_escape() { :; }
fi

tty_mkbold() { tty_escape "1;$1"; }
tty_blue="$(tty_mkbold 34)"
tty_red="$(tty_mkbold 31)"
tty_bold="$(tty_mkbold 39)"
tty_reset="$(tty_escape 0)"

shell_join() {
  local arg
  printf "%s" "$1"
  shift
  for arg in "$@"; do
    printf " %s" "${arg// /\ }"
  done
}

chomp() {
  printf "%s" "${1/"$'\n'"/}"
}

ohai() {
  printf "${tty_blue}==>${tty_bold} %s${tty_reset}\n" "$(shell_join "$@")"
}

warn() {
  printf "${tty_red}Warning${tty_reset}: %s\n" "$(chomp "$1")" >&2
}

ring_bell() {
  if [[ -t 1 ]]; then
    printf "\a"
  fi
}

TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${HOME}/.local/bin"
MARKER='# slurm_tools: PATH'

read_version() {
  local vf="${TOOL_ROOT}/VERSION"
  if [[ -f "$vf" ]]; then
    tr -d '[:space:]' <"$vf" | head -n1
  else
    printf "unknown"
  fi
}

usage() {
  cat <<EOF
usage: $0 [--dry-run]
  Symlinks tools to ${DEST} and appends a PATH snippet to your shell rc.

  Upgrade later: slurm-tools-upgrade (or ${TOOL_ROOT}/upgrade.sh)
EOF
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
    ohai "Would run: ln -sf $(printf '%q' "$src") $(printf '%q' "$dest")"
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
    ohai "Would ensure PATH block in $(printf '%q' "$rc")"
    return 0
  fi
  if [ -f "$rc" ] && grep -qF "$MARKER" "$rc"; then
    ohai "PATH block already present in ${rc}"
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
  ohai "Appended PATH block to ${rc}"
}

append_path_fish() {
  local rc="${HOME}/.config/fish/config.fish"
  if ! $DRY; then
    mkdir -p "$(dirname "$rc")"
    touch "$rc"
  fi
  if $DRY; then
    ohai "Would ensure fish PATH in $(printf '%q' "$rc")"
    return 0
  fi
  if [ -f "$rc" ] && grep -qF "$MARKER" "$rc"; then
    ohai "PATH block already present in ${rc}"
    return 0
  fi
  {
    echo ""
    echo "$MARKER"
    echo 'fish_add_path $HOME/.local/bin'
  } >>"$rc"
  ohai "Appended PATH block to ${rc}"
}

if $DRY; then
  ohai "[dry-run] Would install symlink commands under ${DEST}"
else
  mkdir -p "$DEST"
  ohai "Installing commands into ${DEST}"
fi

if ! $DRY; then
  chmod +x "${TOOL_ROOT}/upgrade.sh" "${TOOL_ROOT}/alloc.sh" \
    "${TOOL_ROOT}/submit_job.sh" "${TOOL_ROOT}/best_partition.sh" \
    "${TOOL_ROOT}/print_alloc.sh" "${TOOL_ROOT}/lib/slurm_common.sh" \
    "${TOOL_ROOT}/dep/node_monitor.py" 2>/dev/null || true
fi

link_one "${TOOL_ROOT}/best_partition.sh" "best_partition"
link_one "${TOOL_ROOT}/print_alloc.sh" "print_alloc"
link_one "${TOOL_ROOT}/dep/node_monitor.py" "node_monitor"
link_one "${TOOL_ROOT}/alloc.sh" "slurm-alloc"
link_one "${TOOL_ROOT}/submit_job.sh" "slurm-submit"
link_one "${TOOL_ROOT}/upgrade.sh" "slurm-tools-upgrade"

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
    warn "Default shell '${shell_base}' not handled; adding PATH to ~/.profile if present."
    if [ -f "${HOME}/.profile" ]; then
      append_path_bash_zsh "${HOME}/.profile"
    else
      append_path_bash_zsh "${HOME}/.bashrc"
    fi
    ;;
esac

if $DRY; then
  ohai "[dry-run] Done."
else
  ring_bell
  ohai "Installation successful!"
  echo
  ohai "Next steps:"
  ver="$(read_version)"
  printf -- "- Version: %s (check upgrades: slurm-tools-upgrade --check)\n" "$ver"
  printf -- "- Commands: best_partition, print_alloc, node_monitor, slurm-alloc, slurm-submit, slurm-tools-upgrade → %s\n" "$DEST"
  printf '%s\n' '- Restart the shell or `source` your rc file so PATH updates.'
fi
