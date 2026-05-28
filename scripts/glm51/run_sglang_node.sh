#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=common.sh
source "${script_dir}/common.sh"

glm51_check_parallelism
glm51_require_model
glm51_prepare_node_local_cache_env

rank="$(glm51_node_rank)"
label="$(glm51_parallelism_label)"
log="${GLM51_LOG_DIR}/sglang.${label}.node${rank}.$(glm51_timestamp).log"

export PYTHONUNBUFFERED=1
export FLASHINFER_DISABLE_VERSION_CHECK=1
export HF_HOME HUGGINGFACE_HUB_CACHE HF_HUB_CACHE TRANSFORMERS_CACHE

mapfile -t args < <(glm51_sglang_args "${rank}")

exec > >(stdbuf -oL tee -a "${log}") 2>&1
echo "=== $(date -Is) backend=sglang host=$(hostname -s) rank=${rank} label=${label} job=${GLM51_JOB_ID} ==="
echo "$(glm51_print_context)"
echo "cache_dirs=x:${XDG_CACHE_HOME} triton:${TRITON_CACHE_DIR} deep_gemm:${DG_JIT_CACHE_DIR} flashinfer:${FLASHINFER_WORKSPACE_BASE}"
echo "cmd: ${GLM51_SGLANG_PYTHON} ${args[*]}"
exec "${GLM51_SGLANG_PYTHON}" "${args[@]}"
