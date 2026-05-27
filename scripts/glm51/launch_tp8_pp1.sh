#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export GLM51_TP=8
export GLM51_PP=1
export GLM51_LAUNCH_SCRIPT_DISPLAY="scripts/glm51/launch_tp8_pp1.sh"

exec "${script_dir}/launch_tp4_pp2.sh" "$@"
