#!/bin/bash
# Check for and apply upgrades from https://github.com/HarvardMadSys/slurm_tools
set -euo pipefail

# shellcheck disable=SC2312

GITHUB_REPO="${SLURM_TOOLS_REPO:-HarvardMadSys/slurm_tools}"
GITHUB_BRANCH="${SLURM_TOOLS_BRANCH:-main}"
RAW_VERSION_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}/VERSION"
TARBALL_URL="https://codeload.github.com/${GITHUB_REPO}/tar.gz/${GITHUB_BRANCH}"

abort() {
  printf "%s\n" "$@" >&2
  exit 1
}

if [[ -z "${BASH_VERSION:-}" ]]; then
  abort "Bash is required to interpret this script."
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

ohai() {
  printf "${tty_blue}==>${tty_bold} %s${tty_reset}\n" "$*"
}

warn() {
  printf "${tty_red}Warning${tty_reset}: %s\n" "$*" >&2
}

read_version_file() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    printf ""
    return 0
  fi
  tr -d '[:space:]' <"$f" | head -n1
}

version_cmp() {
  # Prints -1 if $1 < $2, 0 if equal, 1 if $1 > $2
  local a="$1" b="$2" first
  if [[ -z "$a" || -z "$b" ]]; then
    abort "cannot compare versions (local='${a:-?}' remote='${b:-?}')"
  fi
  if [[ "$a" == "$b" ]]; then
    printf "0"
    return
  fi
  first="$(printf '%s\n%s\n' "$a" "$b" | LC_ALL=C sort -V | head -n1)"
  if [[ "$first" == "$a" ]]; then
    printf "-1"
  else
    printf "1"
  fi
}

fetch_remote_version() {
  local tmp body code
  if ! command -v curl >/dev/null 2>&1; then
    if [[ "${MODE:-}" == "check" ]]; then
      return 1
    fi
    abort "curl is required to check for upgrades."
  fi
  tmp="$(mktemp)"
  code="$(curl -sSL -o "$tmp" -w "%{http_code}" "$RAW_VERSION_URL" 2>/dev/null || true)"
  code="${code//$'\n'/}"
  if [[ "$code" != "200" ]]; then
    rm -f "$tmp"
    return 1
  fi
  body="$(read_version_file "$tmp")"
  rm -f "$tmp"
  if [[ -z "$body" ]]; then
    return 1
  fi
  printf "%s" "$body"
}

resolve_install_root() {
  local cand link target dir

  if [[ -n "${SLURM_TOOLS_ROOT:-}" ]]; then
    cd "${SLURM_TOOLS_ROOT}" && pwd
    return 0
  fi

  for cand in best_partition print_alloc slurm-alloc node_monitor slurm-tools-upgrade; do
    link="${HOME}/.local/bin/${cand}"
    [[ -e "$link" ]] || continue
    if [[ -L "$link" ]]; then
      target="$(readlink "$link")"
      if [[ "$target" != /* ]]; then
        target="$(cd "$(dirname "$link")" && pwd)/${target}"
      fi
      dir="$(cd "$(dirname "$target")" && pwd)"
      if [[ -f "${dir}/VERSION" || -f "${dir}/install.sh" ]]; then
        printf "%s" "$dir"
        return 0
      fi
    elif [[ -f "$link" ]]; then
      dir="$(cd "$(dirname "$link")" && pwd)"
      if [[ -f "${dir}/VERSION" || -f "${dir}/install.sh" ]]; then
        printf "%s" "$dir"
        return 0
      fi
    fi
  done

  if [[ -d "${HOME}/.local/share/slurm_tools" && -f "${HOME}/.local/share/slurm_tools/install.sh" ]]; then
    cd "${HOME}/.local/share/slurm_tools" && pwd
    return 0
  fi

  return 1
}

usage() {
  cat <<EOF
usage: $(basename "$0") [options]

  Check GitHub for a newer release and optionally upgrade the install tree.

Options:
  -c, --check       Compare versions only (exit 0 up to date, 1 upgrade available, 2 check failed)
  -y, --yes         Apply upgrade without prompting (implies upgrade when newer)
  -n, --dry-run     Show what would be done
  -q, --quiet       Minimal output (for scripts, e.g. slurm-alloc)
  -V, --version     Print the installed version and exit
  -h, --help        Show this help

Environment:
  SLURM_TOOLS_ROOT    Install directory (default: resolve via ~/.local/bin symlinks)
  SLURM_TOOLS_BRANCH  Git branch to track (default: main)
  SLURM_TOOLS_REPO    GitHub repo owner/name (default: HarvardMadSys/slurm_tools)
EOF
}

MODE="upgrade"
DRY=false
ASSUME_YES=false
QUIET=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c | --check) MODE="check"; shift ;;
    -y | --yes) ASSUME_YES=true; shift ;;
    -n | --dry-run) DRY=true; shift ;;
    -q | --quiet) QUIET=true; shift ;;
    -V | --version) MODE="version"; shift ;;
    -h | --help) usage; exit 0 ;;
    *) abort "unknown option: $1" ;;
  esac
done

say() {
  if [[ "$QUIET" != "true" ]]; then
    ohai "$@"
  fi
}

INSTALL_ROOT="$(resolve_install_root || true)"
if [[ -z "${INSTALL_ROOT:-}" ]]; then
  abort "Could not find an slurm_tools install. Set SLURM_TOOLS_ROOT or run install.sh first."
fi

LOCAL_VERSION="$(read_version_file "${INSTALL_ROOT}/VERSION")"
if [[ -z "$LOCAL_VERSION" ]]; then
  warn "No VERSION file in ${INSTALL_ROOT}; treating as 0.0.0"
  LOCAL_VERSION="0.0.0"
fi

if [[ "$MODE" == "version" ]]; then
  printf "%s\n" "$LOCAL_VERSION"
  exit 0
fi

say "Install root: ${INSTALL_ROOT}"
say "Installed version: ${LOCAL_VERSION}"

REMOTE_VERSION="$(fetch_remote_version)" || {
  warn "could not fetch ${RAW_VERSION_URL}"
  if [[ "$MODE" == "check" ]]; then
    exit 2
  fi
  abort "version check failed."
}

say "Latest on GitHub (${GITHUB_BRANCH}): ${REMOTE_VERSION}"

cmp="$(version_cmp "$LOCAL_VERSION" "$REMOTE_VERSION")"
if [[ "$cmp" == "0" ]]; then
  say "Already up to date."
  exit 0
fi

if [[ "$cmp" == "1" ]]; then
  warn "Installed version (${LOCAL_VERSION}) is newer than GitHub (${REMOTE_VERSION})."
  exit 0
fi

# cmp == -1: upgrade available
if [[ "$MODE" == "check" ]]; then
  say "Upgrade available: ${LOCAL_VERSION} → ${REMOTE_VERSION}"
  exit 1
fi

if [[ "$ASSUME_YES" != "true" && "$DRY" != "true" ]]; then
  if [[ ! -t 0 ]]; then
    abort "Refusing to upgrade without -y (non-interactive shell)."
  fi
  printf "Upgrade ${LOCAL_VERSION} → ${REMOTE_VERSION}? [y/N] "
  read -r ans
  case "$ans" in
    y | Y | yes | YES) ;;
    *) ohai "Cancelled."; exit 0 ;;
  esac
fi

if [[ "$DRY" == "true" ]]; then
  say "[dry-run] Would download ${TARBALL_URL}"
  say "[dry-run] Would extract into ${INSTALL_ROOT}"
  say "[dry-run] Would run ${INSTALL_ROOT}/install.sh"
  exit 0
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

say "Downloading ${GITHUB_REPO}@${GITHUB_BRANCH}..."
curl -fsSL "$TARBALL_URL" | tar -xz --strip-components=1 -C "$STAGE"

NEW_VER="$(read_version_file "${STAGE}/VERSION")"
if [[ -z "$NEW_VER" ]]; then
  abort "Downloaded tree has no VERSION file."
fi

say "Applying ${NEW_VER} to ${INSTALL_ROOT}..."
# Replace install tree contents; keep user edits only outside tracked files.
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete "${STAGE}/" "${INSTALL_ROOT}/"
else
  find "${INSTALL_ROOT}" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +
  cp -a "${STAGE}/." "${INSTALL_ROOT}/"
fi

if [[ -x "${INSTALL_ROOT}/install.sh" ]]; then
  say "Re-linking commands..."
  "${INSTALL_ROOT}/install.sh"
else
  warn "install.sh missing after upgrade; symlinks may be stale."
fi

say "Upgrade successful! (${LOCAL_VERSION} → ${NEW_VER})"
