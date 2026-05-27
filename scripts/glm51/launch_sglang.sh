#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=common.sh
source "${script_dir}/common.sh"

glm51_check_parallelism
glm51_require_model

if ! "${GLM51_SGLANG_PYTHON}" -c "from importlib.metadata import version; from packaging.version import parse as V; assert V(version('sglang')) >= V('${GLM51_SGLANG_VERSION}')" 2>/dev/null; then
  echo "glm51: need sglang>=${GLM51_SGLANG_VERSION} with ${GLM51_SGLANG_PYTHON}." >&2
  exit 1
fi

nodes="$(glm51_job_nodes_csv)"
label="$(glm51_parallelism_label)"
launcher="${GLM51_SCRIPT_DIR}/run_sglang_node.sh"
master_log="${GLM51_LOG_DIR}/launch_sglang.${label}.$(glm51_timestamp).log"

echo "$(glm51_print_context)"
echo "launching sglang with nodes=${nodes}"

srun --overlap --jobid="${GLM51_JOB_ID}" \
  --nodes="${GLM51_NNODES}" \
  --ntasks="${GLM51_NNODES}" \
  --ntasks-per-node=1 \
  --kill-on-bad-exit=1 \
  -w "${nodes}" \
  bash "${launcher}" \
  >"${master_log}" 2>&1 &

sleep 5
if ! glm51_wait_http_on_head "/v1/models" 2400 "sglang"; then
  echo "glm51: sglang failed to become ready; see ${master_log}." >&2
  exit 1
fi

echo "sglang ready on ${GLM51_HEAD_NODE}:${GLM51_SERVE_PORT}"
echo "master_log=${master_log}"
