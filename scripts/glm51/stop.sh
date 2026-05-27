#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

glm51_load_nodes

tunnel_spec="${GLM51_TUNNEL_BIND}:${GLM51_TUNNEL_PORT}:127.0.0.1:${GLM51_SERVE_PORT}"

srun --overlap --jobid="${GLM51_JOB_ID}" \
  --nodes="${GLM51_NNODES}" \
  --ntasks="${GLM51_NNODES}" \
  --ntasks-per-node=1 \
  -w "$(glm51_job_nodes_csv)" \
  /usr/bin/env GLM51_TUNNEL_SPEC="${tunnel_spec}" GLM51_TUNNEL_HOST="${GLM51_TUNNEL_HOST}" \
  bash --noprofile --norc -lc '
    kill_matches() {
      local pattern="$1"
      local pids
      pids="$(ps -eo pid=,args= | awk -v pat="$pattern" "index(\$0, pat) > 0 && index(\$0, \"awk -v pat\") == 0 {print \$1}")"
      if [[ -n "$pids" ]]; then
        kill -9 $pids >/dev/null 2>&1 || true
      fi
    }
    kill_matches "sglang.launch_server"
    kill_matches "vllm serve"
    kill_matches "vllm.entrypoints"
    kill_matches "raylet"
    kill_matches "gcs_server"
    kill_matches "compile_deep_gemm"
    pkill -f -- "-R ${GLM51_TUNNEL_SPEC} ${GLM51_TUNNEL_HOST}" >/dev/null 2>&1 || true
    pkill -f -- "-R ${GLM51_TUNNEL_SPEC}" >/dev/null 2>&1 || true
  ' >/dev/null 2>&1 || true

sleep 5
echo "stopped sglang/vllm/ray/tunnel on $(glm51_job_nodes_csv)"
