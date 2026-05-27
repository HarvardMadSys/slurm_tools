#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=common.sh
source "${script_dir}/common.sh"

glm51_check_parallelism
glm51_require_model

if ! "${GLM51_VLLM_PYTHON}" -c "from importlib.metadata import version; from packaging.version import parse as V; assert V(version('vllm')) >= V('${GLM51_VLLM_VERSION}')" 2>/dev/null; then
  echo "glm51: need vllm>=${GLM51_VLLM_VERSION} with ${GLM51_VLLM_PYTHON}." >&2
  exit 1
fi

mapfile -t args < <(glm51_vllm_args)
label="$(glm51_parallelism_label)"
vllm_bindir="$(cd "$(dirname "${GLM51_VLLM_PYTHON}")" && pwd)"
if [[ -n "${GLM51_RAY_BIN:-}" ]]; then
  ray_bin="${GLM51_RAY_BIN}"
elif [[ -x "${vllm_bindir}/ray" ]]; then
  ray_bin="${vllm_bindir}/ray"
else
  ray_bin="$(command -v ray)"
fi
if [[ -n "${GLM51_VLLM_BIN:-}" ]]; then
  vllm_bin="${GLM51_VLLM_BIN}"
elif [[ -x "${vllm_bindir}/vllm" ]]; then
  vllm_bin="${vllm_bindir}/vllm"
else
  vllm_bin="$(command -v vllm)"
fi
head_ip="$(glm51_head_ip)"
nodes="$(glm51_job_nodes_csv)"
if [[ -z "${GLM51_VLLM_LD_LIBRARY_PATH}" ]]; then
  export GLM51_VLLM_LD_LIBRARY_PATH="$(glm51_vllm_detect_ld_library_path || true)"
fi

declare -A node_ip
for node in "${GLM51_NODES[@]}"; do
  node_ip["${node}"]="$(glm51_node_ip "${node}")"
done

head_ray_log="${GLM51_LOG_DIR}/ray_head.${label}.$(glm51_timestamp).log"
server_log="${GLM51_LOG_DIR}/vllm.${label}.$(glm51_timestamp).log"

echo "$(glm51_print_context)"
for node in "${GLM51_NODES[@]}"; do
  echo "node_ip[${node}]=${node_ip[${node}]}"
done

head_ray_cmd="$(printf '%q ' "${ray_bin}" start --head --disable-usage-stats --node-ip-address "${head_ip}" --port "${GLM51_RAY_PORT}" --num-gpus "${GLM51_GPUS_PER_NODE}" --block)"
srun --overlap --jobid="${GLM51_JOB_ID}" -N1 -n1 -w "${GLM51_HEAD_NODE}" \
  bash --noprofile --norc -lc "
    source '${script_dir}/common.sh'
    glm51_prepare_node_local_cache_env
    export CUDA_HOME='${GLM51_CUDA_HOME}'
    export VLLM_HOST_IP='${head_ip}'
    export VLLM_SERVER_DEV_MODE='${GLM51_VLLM_DEV_MODE}'
    export NCCL_SOCKET_IFNAME='${GLM51_VLLM_SOCKET_IFNAME}'
    export NCCL_SOCKET_FAMILY=AF_INET
    export GLOO_SOCKET_IFNAME='${GLM51_VLLM_SOCKET_IFNAME}'
    export TP_SOCKET_IFNAME='${GLM51_VLLM_SOCKET_IFNAME}'
    export MASTER_ADDR='${head_ip}'
    export MASTER_PORT='${GLM51_DIST_PORT}'
    export RAY_DEDUP_LOGS=0
    export HF_HOME='${HF_HOME}'
    export HUGGINGFACE_HUB_CACHE='${HUGGINGFACE_HUB_CACHE}'
    export HF_HUB_CACHE='${HF_HUB_CACHE}'
    export TRANSFORMERS_CACHE='${TRANSFORMERS_CACHE}'
    if [[ -n '${GLM51_VLLM_LD_LIBRARY_PATH}' ]]; then
      export LD_LIBRARY_PATH='${GLM51_VLLM_LD_LIBRARY_PATH}:${LD_LIBRARY_PATH}'
    fi
    ${ray_bin} stop -f >/dev/null 2>&1 || true
    ${head_ray_cmd}
  " >"${head_ray_log}" 2>&1 &

sleep 10

for node in "${GLM51_NODES[@]:1}"; do
  worker_log="${GLM51_LOG_DIR}/ray_worker.${label}.${node}.$(glm51_timestamp).log"
  worker_cmd="$(printf '%q ' "${ray_bin}" start --disable-usage-stats --address "${head_ip}:${GLM51_RAY_PORT}" --node-ip-address "${node_ip[${node}]}" --num-gpus "${GLM51_GPUS_PER_NODE}" --block)"
  srun --overlap --jobid="${GLM51_JOB_ID}" -N1 -n1 -w "${node}" \
    bash --noprofile --norc -lc "
      source '${script_dir}/common.sh'
      glm51_prepare_node_local_cache_env
      export CUDA_HOME='${GLM51_CUDA_HOME}'
      export VLLM_HOST_IP='${node_ip[${node}]}'
      export VLLM_SERVER_DEV_MODE='${GLM51_VLLM_DEV_MODE}'
      export NCCL_SOCKET_IFNAME='${GLM51_VLLM_SOCKET_IFNAME}'
      export NCCL_SOCKET_FAMILY=AF_INET
      export GLOO_SOCKET_IFNAME='${GLM51_VLLM_SOCKET_IFNAME}'
      export TP_SOCKET_IFNAME='${GLM51_VLLM_SOCKET_IFNAME}'
      export MASTER_ADDR='${head_ip}'
      export MASTER_PORT='${GLM51_DIST_PORT}'
      export RAY_DEDUP_LOGS=0
      export HF_HOME='${HF_HOME}'
      export HUGGINGFACE_HUB_CACHE='${HUGGINGFACE_HUB_CACHE}'
      export HF_HUB_CACHE='${HF_HUB_CACHE}'
      export TRANSFORMERS_CACHE='${TRANSFORMERS_CACHE}'
      if [[ -n '${GLM51_VLLM_LD_LIBRARY_PATH}' ]]; then
        export LD_LIBRARY_PATH='${GLM51_VLLM_LD_LIBRARY_PATH}:${LD_LIBRARY_PATH}'
      fi
      ${ray_bin} stop -f >/dev/null 2>&1 || true
      ${worker_cmd}
    " >"${worker_log}" 2>&1 &
done

echo "waiting for ray cluster..."
ready=0
started="$(date +%s)"
while true; do
  alive_nodes="$(
    srun --overlap --jobid="${GLM51_JOB_ID}" -N1 -n1 -w "${GLM51_HEAD_NODE}" \
      bash --noprofile --norc -lc \
      "${ray_bin} status --address '${head_ip}:${GLM51_RAY_PORT}' | awk '/^ [0-9]+ node_/{sum+=\$1} END{print sum+0}'" \
      2>/dev/null | tr -d '[:space:]' || true
  )"
  if [[ "${alive_nodes}" =~ ^[0-9]+$ ]] && (( alive_nodes >= GLM51_NNODES )); then
    ready=1
    break
  fi
  if (( $(date +%s) - started >= 300 )); then
    break
  fi
  sleep 5
done
if (( ready == 0 )); then
  echo "glm51: ray cluster did not become ready; see ${head_ray_log}." >&2
  exit 1
fi

vllm_cmd="$(printf '%q ' "${vllm_bin}" "${args[@]}")"
srun --overlap --jobid="${GLM51_JOB_ID}" -N1 -n1 -w "${GLM51_HEAD_NODE}" \
  bash --noprofile --norc -lc "
    source '${script_dir}/common.sh'
    glm51_prepare_node_local_cache_env
    export CUDA_HOME='${GLM51_CUDA_HOME}'
    export VLLM_HOST_IP='${head_ip}'
    export VLLM_SERVER_DEV_MODE='${GLM51_VLLM_DEV_MODE}'
    export NCCL_SOCKET_IFNAME='${GLM51_VLLM_SOCKET_IFNAME}'
    export NCCL_SOCKET_FAMILY=AF_INET
    export GLOO_SOCKET_IFNAME='${GLM51_VLLM_SOCKET_IFNAME}'
    export TP_SOCKET_IFNAME='${GLM51_VLLM_SOCKET_IFNAME}'
    export MASTER_ADDR='${head_ip}'
    export MASTER_PORT='${GLM51_DIST_PORT}'
    export RAY_DEDUP_LOGS=0
    export HF_HOME='${HF_HOME}'
    export HUGGINGFACE_HUB_CACHE='${HUGGINGFACE_HUB_CACHE}'
    export HF_HUB_CACHE='${HF_HUB_CACHE}'
    export TRANSFORMERS_CACHE='${TRANSFORMERS_CACHE}'
    if [[ -n '${GLM51_VLLM_LD_LIBRARY_PATH}' ]]; then
      export LD_LIBRARY_PATH='${GLM51_VLLM_LD_LIBRARY_PATH}:${LD_LIBRARY_PATH}'
    fi
    ${vllm_cmd}
  " >"${server_log}" 2>&1 &
server_pid=$!

sleep 10
ready=0
started="$(date +%s)"
while true; do
  if srun --overlap --jobid="${GLM51_JOB_ID}" -N1 -n1 -w "${GLM51_HEAD_NODE}" \
    bash --noprofile --norc -lc \
    "curl -fsS --max-time 5 http://127.0.0.1:${GLM51_SERVE_PORT}/v1/models >/dev/null" \
    >/dev/null 2>&1; then
    ready=1
    break
  fi
  if ! kill -0 "${server_pid}" >/dev/null 2>&1; then
    break
  fi
  if (( $(date +%s) - started >= GLM51_VLLM_READY_TIMEOUT )); then
    break
  fi
  sleep 5
done
if (( ready == 0 )); then
  echo "glm51: vllm failed to become ready; see ${server_log}." >&2
  exit 1
fi

echo "vllm ready on ${GLM51_HEAD_NODE}:${GLM51_SERVE_PORT}"
echo "ray_head_log=${head_ray_log}"
echo "server_log=${server_log}"
