#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=common.sh
source "${script_dir}/common.sh"

display_script="${GLM51_LAUNCH_SCRIPT_DISPLAY:-scripts/glm51/$(basename "${BASH_SOURCE[0]}")}"

usage() {
  cat <<EOF
Usage:
  ${display_script} sglang [options]
  ${display_script} vllm [options]

Options:
  --background, -b        Run the launcher in the background and return immediately.
  --foreground            Run the launcher in the foreground until the server is ready.
  --stop-first            Stop existing SGLang/vLLM/Ray processes before launching.
  --job-id JOB_ID         Slurm allocation job id. Defaults to GLM51_JOB_ID/SLURM_JOB_ID/autodetect.
  --port PORT             OpenAI-compatible HTTP server port. Defaults to GLM51_SERVE_PORT/30000.
  --dist-port PORT        Distributed init port. Defaults to GLM51_DIST_PORT/29500.
  --ray-port PORT         Ray port for vLLM. Defaults to GLM51_RAY_PORT/6379.
  --tunnel                Start a reverse SSH tunnel after the server is ready.
  --no-tunnel             Do not start a reverse SSH tunnel.
  --tunnel-host HOST      Reverse tunnel host. Defaults to GLM51_TUNNEL_HOST/internal.freeinference.org.
  --tunnel-port PORT      Reverse tunnel port. Defaults to GLM51_TUNNEL_PORT/8002.
  --tunnel-bind ADDR      Remote bind address. Defaults to GLM51_TUNNEL_BIND/0.0.0.0.
  --help, -h              Show this help.

Examples:
  GLM51_JOB_ID=15378036 ${display_script} sglang --stop-first --tunnel
  GLM51_JOB_ID=15378036 ${display_script} vllm --stop-first

The service keeps running inside the Slurm allocation after this script reports
readiness. Stop it with:
  scripts/glm51/stop.sh
EOF
}

backend=""
background=0
stop_first=0
tunnel=0

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    sglang|vllm)
      if [[ -n "${backend}" ]]; then
        echo "glm51: backend already set to ${backend}." >&2
        exit 2
      fi
      backend="$1"
      ;;
    --background|-b)
      background=1
      ;;
    --foreground)
      background=0
      ;;
    --stop-first)
      stop_first=1
      ;;
    --job-id)
      if [[ "$#" -lt 2 ]]; then
        echo "glm51: --job-id requires a value." >&2
        exit 2
      fi
      export GLM51_JOB_ID="$2"
      shift
      ;;
    --port|--serve-port)
      if [[ "$#" -lt 2 ]]; then
        echo "glm51: $1 requires a value." >&2
        exit 2
      fi
      export GLM51_SERVE_PORT="$2"
      shift
      ;;
    --dist-port)
      if [[ "$#" -lt 2 ]]; then
        echo "glm51: --dist-port requires a value." >&2
        exit 2
      fi
      export GLM51_DIST_PORT="$2"
      shift
      ;;
    --ray-port)
      if [[ "$#" -lt 2 ]]; then
        echo "glm51: --ray-port requires a value." >&2
        exit 2
      fi
      export GLM51_RAY_PORT="$2"
      shift
      ;;
    --tunnel)
      tunnel=1
      ;;
    --no-tunnel)
      tunnel=0
      ;;
    --tunnel-host)
      if [[ "$#" -lt 2 ]]; then
        echo "glm51: --tunnel-host requires a value." >&2
        exit 2
      fi
      export GLM51_TUNNEL_HOST="$2"
      shift
      ;;
    --tunnel-port)
      if [[ "$#" -lt 2 ]]; then
        echo "glm51: --tunnel-port requires a value." >&2
        exit 2
      fi
      export GLM51_TUNNEL_PORT="$2"
      shift
      ;;
    --tunnel-bind)
      if [[ "$#" -lt 2 ]]; then
        echo "glm51: --tunnel-bind requires a value." >&2
        exit 2
      fi
      export GLM51_TUNNEL_BIND="$2"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "glm51: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ -z "${backend}" ]]; then
  echo "glm51: choose backend: sglang or vllm." >&2
  usage >&2
  exit 2
fi

label="$(glm51_parallelism_label)"
launcher="${script_dir}/launch_${backend}.sh"

glm51_tunnel_file_prefix() {
  printf '%s_%s' "${GLM51_TUNNEL_HOST}" "${GLM51_TUNNEL_PORT}" \
    | tr -cs 'A-Za-z0-9._-' '_'
}

stop_reverse_tunnel() {
  glm51_load_nodes
  local tunnel_spec="${GLM51_TUNNEL_BIND}:${GLM51_TUNNEL_PORT}:127.0.0.1:${GLM51_SERVE_PORT}"
  srun --overlap --jobid="${GLM51_JOB_ID}" -N1 -n1 -w "${GLM51_HEAD_NODE}" \
    /usr/bin/env GLM51_TUNNEL_SPEC="${tunnel_spec}" GLM51_TUNNEL_HOST="${GLM51_TUNNEL_HOST}" \
    bash --noprofile --norc -lc \
    'pkill -f -- "-R ${GLM51_TUNNEL_SPEC} ${GLM51_TUNNEL_HOST}" >/dev/null 2>&1 || true
     pkill -f -- "-R ${GLM51_TUNNEL_SPEC}" >/dev/null 2>&1 || true' \
    >/dev/null 2>&1 || true
}

start_reverse_tunnel() {
  glm51_load_nodes
  mkdir -p "${GLM51_TUNNEL_LOG_DIR}"

  local tunnel_spec="${GLM51_TUNNEL_BIND}:${GLM51_TUNNEL_PORT}:127.0.0.1:${GLM51_SERVE_PORT}"
  local prefix stamp tunnel_log info_file pid_file local_pid_file remote_pid
  prefix="$(glm51_tunnel_file_prefix)"
  stamp="$(glm51_timestamp)"
  tunnel_log="${GLM51_TUNNEL_LOG_DIR}/${prefix}.${stamp}.log"
  info_file="${GLM51_TUNNEL_LOG_DIR}/${prefix}.info"
  pid_file="${GLM51_TUNNEL_LOG_DIR}/${prefix}.pid"
  local_pid_file="${GLM51_TUNNEL_LOG_DIR}/${prefix}.local_srun_pid"

  stop_reverse_tunnel

  srun --overlap --jobid="${GLM51_JOB_ID}" -N1 -n1 -w "${GLM51_HEAD_NODE}" \
    bash --noprofile --norc -lc \
    "ssh -N -T -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new -R '${tunnel_spec}' '${GLM51_TUNNEL_HOST}'" \
    >"${tunnel_log}" 2>&1 &
  printf '%s\n' "$!" > "${local_pid_file}"

  sleep 5
  remote_pid="$(
    srun --overlap --jobid="${GLM51_JOB_ID}" -N1 -n1 -w "${GLM51_HEAD_NODE}" \
      /usr/bin/env GLM51_TUNNEL_SPEC="${tunnel_spec}" GLM51_TUNNEL_HOST="${GLM51_TUNNEL_HOST}" \
      bash --noprofile --norc -lc \
      'pgrep -u "${USER}" -f -- "ssh .* -R ${GLM51_TUNNEL_SPEC} .*${GLM51_TUNNEL_HOST}" | head -1' \
      2>/dev/null | tr -d '[:space:]' || true
  )"

  if [[ -z "${remote_pid}" ]]; then
    echo "glm51: failed to start reverse SSH tunnel; see ${tunnel_log}." >&2
    sed -n '1,120p' "${tunnel_log}" >&2 || true
    return 1
  fi

  printf '%s\n' "${remote_pid}" > "${pid_file}"
  {
    printf 'head_node=%s\n' "${GLM51_HEAD_NODE}"
    printf 'remote_host=%s\n' "${GLM51_TUNNEL_HOST}"
    printf 'remote_bind=%s\n' "${GLM51_TUNNEL_BIND}"
    printf 'remote_port=%s\n' "${GLM51_TUNNEL_PORT}"
    printf 'local_target=127.0.0.1:%s\n' "${GLM51_SERVE_PORT}"
    printf 'ssh_pid_on_head=%s\n' "${remote_pid}"
    printf 'job_id=%s\n' "${GLM51_JOB_ID}"
    printf 'tunnel_log=%s\n' "${tunnel_log}"
  } > "${info_file}"

  if ssh -o BatchMode=yes -o ConnectTimeout=8 "${GLM51_TUNNEL_HOST}" \
    "ss -ltn sport = :${GLM51_TUNNEL_PORT}" >/dev/null 2>&1; then
    echo "tunnel ready on ${GLM51_TUNNEL_HOST}:${GLM51_TUNNEL_PORT}"
  else
    echo "tunnel process started; remote listener check failed, see ${info_file}" >&2
  fi
  echo "tunnel_info=${info_file}"
  echo "tunnel_pid=${remote_pid}"
}

run_launch() {
  echo "=== $(date -Is) launching ${backend} ${label} ==="
  echo "$(glm51_print_context)"
  if (( stop_first == 1 )); then
    if (( tunnel == 1 )); then
      stop_reverse_tunnel
    fi
    "${script_dir}/stop.sh"
  fi
  bash "${launcher}"
  if (( tunnel == 1 )); then
    start_reverse_tunnel
  fi
}

if (( background == 1 )); then
  mkdir -p "${GLM51_LOG_DIR}"
  stamp="$(glm51_timestamp)"
  bg_log="${GLM51_LOG_DIR}/launch_${backend}.${label}.background.${stamp}.log"
  pid_file="${GLM51_LOG_DIR}/launch_${backend}.${label}.background.pid"
  (
    trap '' HUP
    run_launch
  ) >"${bg_log}" 2>&1 &
  bg_pid="$!"
  printf '%s\n' "${bg_pid}" >"${pid_file}"
  disown "${bg_pid}" >/dev/null 2>&1 || true
  echo "started ${backend} ${label} launcher in background"
  echo "launcher_pid=${bg_pid}"
  echo "launcher_log=${bg_log}"
  echo "pid_file=${pid_file}"
  if (( tunnel == 1 )); then
    echo "tunnel_requested=${GLM51_TUNNEL_HOST}:${GLM51_TUNNEL_PORT}"
    echo "tunnel_info=${GLM51_TUNNEL_LOG_DIR}/$(glm51_tunnel_file_prefix).info"
  fi
  echo "stop_with=${script_dir}/stop.sh"
  exit 0
fi

run_launch
