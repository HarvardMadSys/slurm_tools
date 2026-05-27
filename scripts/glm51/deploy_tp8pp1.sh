#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

backend="sglang"
if [[ "$#" -gt 0 ]]; then
  case "$1" in
    sglang|vllm)
      backend="$1"
      shift
      ;;
  esac
fi

has_stop_first=0
has_tunnel_choice=0
for arg in "$@"; do
  case "${arg}" in
    --stop-first)
      has_stop_first=1
      ;;
    --tunnel|--no-tunnel)
      has_tunnel_choice=1
      ;;
  esac
done

args=("${backend}")
if [[ "${has_stop_first}" == "0" ]]; then
  args+=(--stop-first)
fi
if [[ "${has_tunnel_choice}" == "0" ]]; then
  args+=(--tunnel)
fi
args+=("$@")

exec "${script_dir}/launch_tp8_pp1.sh" "${args[@]}"
