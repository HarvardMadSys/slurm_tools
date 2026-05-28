#!/usr/bin/env bash
# Common helpers for launching and benchmarking GLM-5.1-FP8 on a 2x4xH200 Slurm allocation.
set -euo pipefail

GLM51_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GLM51_REPO_DIR="$(cd "${GLM51_SCRIPT_DIR}/../.." && pwd)"

export GLM51_PYTHON="${GLM51_PYTHON:-/n/sw/Miniforge3-25.3.1-0/bin/python3}"
export GLM51_SGLANG_PYTHON="${GLM51_SGLANG_PYTHON:-${GLM51_PYTHON}}"
export GLM51_VLLM_PYTHON="${GLM51_VLLM_PYTHON:-/n/netscratch/juncheng_lab/venvs/vllm-0.21.0-cu129/bin/python}"
export GLM51_CUDA_HOME="${GLM51_CUDA_HOME:-/n/sw/helmod-rocky8/apps/Core/cuda/12.9.1-fasrc01/cuda}"
export GLM51_GCC_HOME="${GLM51_GCC_HOME:-/n/sw/helmod-rocky8/apps/Core/gcc/13.2.0-fasrc01}"
export GLM51_GMP_HOME="${GLM51_GMP_HOME:-/n/sw/helmod-rocky8/apps/Core/gmp/6.3.0-fasrc01}"
export GLM51_MPC_HOME="${GLM51_MPC_HOME:-/n/sw/helmod-rocky8/apps/Core/mpc/1.3.1-fasrc03}"
export GLM51_MPFR_HOME="${GLM51_MPFR_HOME:-/n/sw/helmod-rocky8/apps/Core/mpfr/4.2.2-fasrc01}"
export GLM51_JOB_ID="${GLM51_JOB_ID:-${SLURM_JOB_ID:-}}"
export GLM51_MODEL_ROOT="${GLM51_MODEL_ROOT:-/n/netscratch/juncheng_lab/model}"
export GLM51_MODEL_LOCAL="${GLM51_MODEL_LOCAL:-${GLM51_MODEL_ROOT}/GLM-5.1-FP8-2}"
export GLM51_HF_REPO="${GLM51_HF_REPO:-zai-org/GLM-5.1-FP8}"
export GLM51_TP="${GLM51_TP:-4}"
export GLM51_PP="${GLM51_PP:-2}"
export GLM51_GPUS_PER_NODE="${GLM51_GPUS_PER_NODE:-4}"
export GLM51_CONTEXT_LENGTH="${GLM51_CONTEXT_LENGTH:-202752}"
export GLM51_DIST_PORT="${GLM51_DIST_PORT:-29500}"
export GLM51_RAY_PORT="${GLM51_RAY_PORT:-6379}"
export GLM51_SERVE_PORT="${GLM51_SERVE_PORT:-30000}"
export GLM51_LOG_DIR="${GLM51_LOG_DIR:-${GLM51_REPO_DIR}/logs/glm51}"
export GLM51_RESULTS_DIR="${GLM51_RESULTS_DIR:-${GLM51_LOG_DIR}/results}"
export GLM51_TUNNEL_HOST="${GLM51_TUNNEL_HOST:-internal.freeinference.org}"
export GLM51_TUNNEL_PORT="${GLM51_TUNNEL_PORT:-8002}"
export GLM51_TUNNEL_BIND="${GLM51_TUNNEL_BIND:-0.0.0.0}"
export GLM51_TUNNEL_LOG_DIR="${GLM51_TUNNEL_LOG_DIR:-${GLM51_LOG_DIR}/tunnels}"
export GLM51_TOKENIZER_MODE="${GLM51_TOKENIZER_MODE:-slow}"
export GLM51_TOOL_CALL_PARSER="${GLM51_TOOL_CALL_PARSER:-glm47}"
export GLM51_MEM_FRACTION_STATIC="${GLM51_MEM_FRACTION_STATIC:-0.75}"
export GLM51_CHUNKED_PREFILL_SIZE="${GLM51_CHUNKED_PREFILL_SIZE:-131072}"
export GLM51_SGLANG_CUDA_GRAPH_MAX_BS="${GLM51_SGLANG_CUDA_GRAPH_MAX_BS:-128}"
export GLM51_SGLANG_CUDA_GRAPH_MAX_BS_PP="${GLM51_SGLANG_CUDA_GRAPH_MAX_BS_PP:-16}"
export GLM51_SGLANG_DISABLE_CUDA_GRAPH_PP="${GLM51_SGLANG_DISABLE_CUDA_GRAPH_PP:-1}"
export GLM51_WATCHDOG_TIMEOUT="${GLM51_WATCHDOG_TIMEOUT:-1800}"
export GLM51_QUANTIZATION="${GLM51_QUANTIZATION:-}"
export GLM51_VLLM_VERSION="${GLM51_VLLM_VERSION:-0.21.0}"
export GLM51_SGLANG_VERSION="${GLM51_SGLANG_VERSION:-0.5.10.post1}"
export GLM51_VLLM_DEV_MODE="${GLM51_VLLM_DEV_MODE:-1}"
export GLM51_VLLM_LD_LIBRARY_PATH="${GLM51_VLLM_LD_LIBRARY_PATH:-}"
export GLM51_VLLM_SOCKET_IFNAME="${GLM51_VLLM_SOCKET_IFNAME:-ib0}"
export GLM51_NODE_IP_IFNAME="${GLM51_NODE_IP_IFNAME:-${GLM51_VLLM_SOCKET_IFNAME}}"
export GLM51_VLLM_DISABLE_CUSTOM_ALL_REDUCE="${GLM51_VLLM_DISABLE_CUSTOM_ALL_REDUCE:-1}"
export GLM51_VLLM_READY_TIMEOUT="${GLM51_VLLM_READY_TIMEOUT:-3600}"
export GLM51_BENCH_CASE_TIMEOUT="${GLM51_BENCH_CASE_TIMEOUT:-3600}"
export PYTHONUNBUFFERED=1
export PYTORCH_ALLOC_CONF="${PYTORCH_ALLOC_CONF:-expandable_segments:True}"
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-${PYTORCH_ALLOC_CONF}}"
export FLASHINFER_DISABLE_VERSION_CHECK="${FLASHINFER_DISABLE_VERSION_CHECK:-1}"
export HF_HOME="${HF_HOME:-/n/netscratch/juncheng_lab/hf}"
export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-${HF_HOME}/hub}"
export HF_HUB_CACHE="${HF_HUB_CACHE:-${HUGGINGFACE_HUB_CACHE}}"
export TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE:-${HF_HOME}/transformers}"
export CC="${CC:-${GLM51_GCC_HOME}/bin/gcc}"
export CXX="${CXX:-${GLM51_GCC_HOME}/bin/g++}"
export CUDAHOSTCXX="${CUDAHOSTCXX:-${CXX}}"
export PATH="${GLM51_GCC_HOME}/bin:${GLM51_CUDA_HOME}/bin:${PATH}"
if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
  export LD_LIBRARY_PATH="${GLM51_GMP_HOME}/lib64:${GLM51_MPC_HOME}/lib64:${GLM51_MPFR_HOME}/lib64:${GLM51_GCC_HOME}/lib64:${GLM51_GCC_HOME}/lib:${GLM51_CUDA_HOME}/lib64:${GLM51_CUDA_HOME}/lib:${GLM51_CUDA_HOME}/extras/CUPTI/lib64:${LD_LIBRARY_PATH}"
else
  export LD_LIBRARY_PATH="${GLM51_GMP_HOME}/lib64:${GLM51_MPC_HOME}/lib64:${GLM51_MPFR_HOME}/lib64:${GLM51_GCC_HOME}/lib64:${GLM51_GCC_HOME}/lib:${GLM51_CUDA_HOME}/lib64:${GLM51_CUDA_HOME}/lib:${GLM51_CUDA_HOME}/extras/CUPTI/lib64"
fi

mkdir -p "${GLM51_LOG_DIR}" "${GLM51_RESULTS_DIR}" "${GLM51_TUNNEL_LOG_DIR}" "${HF_HOME}" \
  "${HUGGINGFACE_HUB_CACHE}" "${TRANSFORMERS_CACHE}"

glm51_autodetect_job() {
  if [[ -n "${GLM51_JOB_ID}" ]]; then
    return 0
  fi

  local detected
  detected="$(squeue -u "${USER}" -h -t RUNNING -o "%i %P %D" \
    | awk '$2 ~ /h200/ && $3 == 2 {print $1; exit}')"
  if [[ -n "${detected}" ]]; then
    export GLM51_JOB_ID="${detected}"
  fi
}

glm51_require_job() {
  glm51_autodetect_job
  if [[ -z "${GLM51_JOB_ID}" ]]; then
    echo "glm51: set GLM51_JOB_ID or run inside the allocated Slurm job." >&2
    exit 1
  fi
  local state
  state="$(squeue -j "${GLM51_JOB_ID}" -h -o "%T")"
  if [[ "${state}" != "RUNNING" ]]; then
    echo "glm51: job ${GLM51_JOB_ID} is not RUNNING (state=${state:-unknown})." >&2
    exit 1
  fi
}

glm51_load_nodes() {
  glm51_require_job
  mapfile -t GLM51_NODES < <(
    scontrol show hostnames "$(squeue -j "${GLM51_JOB_ID}" -h -o "%N")"
  )
  if [[ "${#GLM51_NODES[@]}" -lt 1 ]]; then
    echo "glm51: failed to resolve nodes for job ${GLM51_JOB_ID}." >&2
    exit 1
  fi
  export GLM51_NNODES="${#GLM51_NODES[@]}"
  export GLM51_HEAD_NODE="${GLM51_HEAD_NODE:-${GLM51_NODES[0]}}"
  export GLM51_NODE0="${GLM51_NODE0:-${GLM51_NODES[0]}}"
  if [[ "${#GLM51_NODES[@]}" -ge 2 ]]; then
    export GLM51_NODE1="${GLM51_NODE1:-${GLM51_NODES[1]}}"
  fi
}

glm51_job_nodes_csv() {
  glm51_load_nodes
  local IFS=,
  printf '%s' "${GLM51_NODES[*]}"
}

glm51_require_model() {
  if [[ -f "${GLM51_MODEL_LOCAL}/config.json" ]]; then
    export GLM51_MODEL="${GLM51_MODEL:-${GLM51_MODEL_LOCAL}}"
    return 0
  fi
  if [[ -n "${GLM51_MODEL:-}" && -f "${GLM51_MODEL}/config.json" ]]; then
    return 0
  fi
  echo "glm51: local model not found at ${GLM51_MODEL_LOCAL}." >&2
  exit 1
}

glm51_parallelism_label() {
  printf 'tp%s_pp%s' "${GLM51_TP}" "${GLM51_PP}"
}

glm51_prepare_node_local_cache_env() {
  local host="${1:-$(hostname -s)}"
  local job_id="${GLM51_JOB_ID:-nojob}"
  local label
  label="$(glm51_parallelism_label)"

  local base_root="${GLM51_LOCAL_CACHE_ROOT:-${TMPDIR:-/tmp}/${USER}/glm51}"
  local base_dir="${base_root}/${job_id}/${host}/shared"
  local legacy_dir="${base_root}/${job_id}/${host}/${label}"

  mkdir -p "${base_dir}"

  cache_dir_with_legacy_fallback() {
    local shared_path="${1:?missing shared path}"
    local legacy_path="${2:?missing legacy path}"
    mkdir -p "$(dirname "${shared_path}")"
    if [[ ! -e "${shared_path}" && -e "${legacy_path}" ]]; then
      ln -s "${legacy_path}" "${shared_path}"
    fi
    printf '%s\n' "${shared_path}"
  }

  export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$(cache_dir_with_legacy_fallback "${base_dir}/xdg-cache" "${legacy_dir}/xdg-cache")}"
  export TRITON_CACHE_DIR="${TRITON_CACHE_DIR:-$(cache_dir_with_legacy_fallback "${base_dir}/triton" "${legacy_dir}/triton")}"
  export DG_JIT_CACHE_DIR="${DG_JIT_CACHE_DIR:-$(cache_dir_with_legacy_fallback "${base_dir}/deep_gemm/cache" "${legacy_dir}/deep_gemm/cache")}"
  export TORCH_EXTENSIONS_DIR="${TORCH_EXTENSIONS_DIR:-$(cache_dir_with_legacy_fallback "${base_dir}/torch_extensions" "${legacy_dir}/torch_extensions")}"
  export TORCHINDUCTOR_CACHE_DIR="${TORCHINDUCTOR_CACHE_DIR:-$(cache_dir_with_legacy_fallback "${base_dir}/torchinductor" "${legacy_dir}/torchinductor")}"
  export FLASHINFER_WORKSPACE_BASE="${FLASHINFER_WORKSPACE_BASE:-$(cache_dir_with_legacy_fallback "${base_dir}/flashinfer" "${legacy_dir}/flashinfer")}"

  mkdir -p \
    "${XDG_CACHE_HOME}" \
    "${TRITON_CACHE_DIR}" \
    "${DG_JIT_CACHE_DIR}" \
    "${TORCH_EXTENSIONS_DIR}" \
    "${TORCHINDUCTOR_CACHE_DIR}" \
    "${FLASHINFER_WORKSPACE_BASE}"
}

glm51_check_parallelism() {
  glm51_load_nodes
  local world_size expected_world_size
  world_size=$((GLM51_TP * GLM51_PP))
  expected_world_size=$((GLM51_NNODES * GLM51_GPUS_PER_NODE))
  if [[ "${world_size}" -ne "${expected_world_size}" ]]; then
    echo "glm51: tp*pp must equal nnodes*gpus_per_node (${world_size} != ${expected_world_size})." >&2
    exit 1
  fi
}

glm51_node_rank() {
  if [[ -n "${SLURM_NODEID:-}" ]]; then
    printf '%s\n' "${SLURM_NODEID}"
    return 0
  fi
  glm51_load_nodes
  local host idx
  host="$(hostname -s)"
  for idx in "${!GLM51_NODES[@]}"; do
    if [[ "${GLM51_NODES[$idx]}" == "${host}" ]]; then
      printf '%s\n' "${idx}"
      return 0
    fi
  done
  echo "glm51: cannot infer node rank for host ${host}." >&2
  exit 1
}

glm51_node_ip() {
  local host="${1:?missing host}"
  local ifname="${GLM51_NODE_IP_IFNAME:-}"
  if [[ -n "${ifname}" ]]; then
    local ip_addr
    ip_addr="$(
      srun --overlap --jobid="${GLM51_JOB_ID}" -N1 -n1 -w "${host}" \
        bash --noprofile --norc -lc \
        "ip -4 -o addr show dev '${ifname}' scope global | awk '{sub(/\\/.*/, \"\", \$4); print \$4; exit}'" \
        2>/dev/null | tr -d '[:space:]' || true
    )"
    if [[ -n "${ip_addr}" ]]; then
      printf '%s\n' "${ip_addr}"
      return 0
    fi
  fi
  srun --overlap --jobid="${GLM51_JOB_ID}" -N1 -n1 -w "${host}" \
    bash --noprofile --norc -lc \
    "ip route get 8.8.8.8 | awk '{print \$7; exit}'"
}

glm51_head_ip() {
  glm51_load_nodes
  if [[ -n "${GLM51_HEAD_IP:-}" ]]; then
    printf '%s\n' "${GLM51_HEAD_IP}"
    return 0
  fi
  export GLM51_HEAD_IP="$(glm51_node_ip "${GLM51_HEAD_NODE}")"
  printf '%s\n' "${GLM51_HEAD_IP}"
}

glm51_wait_http_on_head() {
  local path="${1:?missing path}"
  local timeout="${2:-900}"
  local label="${3:-server}"
  local started now
  started="$(date +%s)"
  while true; do
    if srun --overlap --jobid="${GLM51_JOB_ID}" -N1 -n1 -w "${GLM51_HEAD_NODE}" \
      bash --noprofile --norc -lc \
      "curl -fsS --max-time 5 http://127.0.0.1:${GLM51_SERVE_PORT}${path} >/dev/null" \
      >/dev/null 2>&1; then
      return 0
    fi
    now="$(date +%s)"
    if (( now - started >= timeout )); then
      echo "glm51: timed out waiting for ${label} on ${GLM51_HEAD_NODE}:${GLM51_SERVE_PORT}${path}." >&2
      return 1
    fi
    sleep 5
  done
}

glm51_timestamp() {
  date +%Y%m%d_%H%M%S
}

glm51_vllm_detect_ld_library_path() {
  "${GLM51_VLLM_PYTHON}" - <<'PY'
import os
import site

paths = []
seen = set()

def add(path):
    if path and os.path.isdir(path) and path not in seen:
        seen.add(path)
        paths.append(path)

for base in site.getsitepackages():
    add(os.path.join(base, "torch", "lib"))
    nvidia_root = os.path.join(base, "nvidia")
    if os.path.isdir(nvidia_root):
        for root, dirs, files in os.walk(nvidia_root):
            if os.path.basename(root) == "lib":
                add(root)

print(":".join(paths))
PY
}

glm51_sglang_args() {
  local rank="${1:?missing node rank}"
  glm51_load_nodes
  glm51_require_model
  local cuda_graph_max_bs="${GLM51_SGLANG_CUDA_GRAPH_MAX_BS}"
  if [[ "${GLM51_PP}" -gt 1 ]]; then
    cuda_graph_max_bs="${GLM51_SGLANG_CUDA_GRAPH_MAX_BS_PP}"
  fi
  local args=(
    -m sglang.launch_server
    --model-path "${GLM51_MODEL}"
    --tokenizer-path "${GLM51_MODEL}"
    --tokenizer-mode "${GLM51_TOKENIZER_MODE}"
    --trust-remote-code
    --tp-size "${GLM51_TP}"
    --pp-size "${GLM51_PP}"
    --nnodes "${GLM51_NNODES}"
    --node-rank "${rank}"
    --dist-init-addr "$(glm51_head_ip):${GLM51_DIST_PORT}"
    --host 0.0.0.0
    --port "${GLM51_SERVE_PORT}"
    --context-length "${GLM51_CONTEXT_LENGTH}"
    --chunked-prefill-size "${GLM51_CHUNKED_PREFILL_SIZE}"
    --cuda-graph-max-bs "${cuda_graph_max_bs}"
    --mem-fraction-static "${GLM51_MEM_FRACTION_STATIC}"
    --watchdog-timeout "${GLM51_WATCHDOG_TIMEOUT}"
    --disable-radix-cache
    --enable-metrics
  )
  if [[ -n "${GLM51_QUANTIZATION}" ]]; then
    args+=(--quantization "${GLM51_QUANTIZATION}")
  fi
  if [[ -n "${GLM51_TOOL_CALL_PARSER}" ]]; then
    args+=(--tool-call-parser "${GLM51_TOOL_CALL_PARSER}")
  fi
  if [[ "${GLM51_PP}" -gt 1 ]]; then
    args+=(--disable-overlap-schedule)
    if [[ "${GLM51_SGLANG_DISABLE_CUDA_GRAPH_PP}" == "1" ]]; then
      args+=(--disable-cuda-graph)
    fi
  fi
  printf '%s\n' "${args[@]}"
}

glm51_vllm_args() {
  glm51_load_nodes
  glm51_require_model
  local args=(
    serve "${GLM51_MODEL}"
    --tensor-parallel-size "${GLM51_TP}"
    --pipeline-parallel-size "${GLM51_PP}"
    --distributed-executor-backend ray
    --trust-remote-code
    --tokenizer "${GLM51_MODEL}"
    --tokenizer-mode "${GLM51_TOKENIZER_MODE}"
    --max-model-len "${GLM51_CONTEXT_LENGTH}"
    --host 0.0.0.0
    --port "${GLM51_SERVE_PORT}"
    --no-enable-prefix-caching
    --gpu-memory-utilization 0.9
  )
  if [[ "${GLM51_VLLM_DISABLE_CUSTOM_ALL_REDUCE}" == "1" ]]; then
    args+=(--disable-custom-all-reduce)
  fi
  printf '%s\n' "${args[@]}"
}

glm51_print_context() {
  glm51_load_nodes
  glm51_require_model
  cat <<EOF
job_id=${GLM51_JOB_ID}
nodes=$(glm51_job_nodes_csv)
head_node=${GLM51_HEAD_NODE}
model=${GLM51_MODEL}
context_length=${GLM51_CONTEXT_LENGTH}
parallelism=$(glm51_parallelism_label)
ports=serve:${GLM51_SERVE_PORT},dist:${GLM51_DIST_PORT},ray:${GLM51_RAY_PORT}
logs=${GLM51_LOG_DIR}
results=${GLM51_RESULTS_DIR}
EOF
}
