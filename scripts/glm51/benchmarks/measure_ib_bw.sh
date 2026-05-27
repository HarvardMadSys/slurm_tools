#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
glm51_dir="$(cd "${script_dir}/.." && pwd)"

# shellcheck source=../common.sh
source "${glm51_dir}/common.sh"

glm51_load_nodes

if [[ "${GLM51_NNODES}" -lt 2 ]]; then
  echo "glm51: need at least 2 nodes to measure inter-node bandwidth." >&2
  exit 1
fi

export GLM51_BW_IFACE="${GLM51_BW_IFACE:-ib0}"
export GLM51_BW_DURATION="${GLM51_BW_DURATION:-10}"
export GLM51_BW_PORT="${GLM51_BW_PORT:-18515}"
export GLM51_BW_RESULTS_DIR="${GLM51_BW_RESULTS_DIR:-${GLM51_RESULTS_DIR}/bandwidth}"

server_node="${GLM51_NODES[0]}"
client_node="${GLM51_NODES[1]}"
timestamp="$(glm51_timestamp)"
run_dir="${GLM51_BW_RESULTS_DIR}/${timestamp}"
mkdir -p "${run_dir}"

detect_dev_cmd="ibdev2netdev | awk '\$5 == \"${GLM51_BW_IFACE}\" {print \$1; exit}'"
ib_dev="$(
  srun --overlap --jobid="${GLM51_JOB_ID}" -N1 -n1 -w "${server_node}" \
    bash --noprofile --norc -lc "${detect_dev_cmd}"
)"

if [[ -z "${ib_dev}" ]]; then
  echo "glm51: failed to map ${GLM51_BW_IFACE} to an IB device." >&2
  exit 1
fi

server_ip="$(
  srun --overlap --jobid="${GLM51_JOB_ID}" -N1 -n1 -w "${server_node}" \
    bash --noprofile --norc -lc \
    "ip -4 -o addr show dev '${GLM51_BW_IFACE}' scope global | awk '{sub(/\\/.*/, \"\", \$4); print \$4; exit}'"
)"
client_ip="$(
  srun --overlap --jobid="${GLM51_JOB_ID}" -N1 -n1 -w "${client_node}" \
    bash --noprofile --norc -lc \
    "ip -4 -o addr show dev '${GLM51_BW_IFACE}' scope global | awk '{sub(/\\/.*/, \"\", \$4); print \$4; exit}'"
)"

context_path="${run_dir}/context.txt"
cat >"${context_path}" <<EOF
job_id=${GLM51_JOB_ID}
server_node=${server_node}
client_node=${client_node}
iface=${GLM51_BW_IFACE}
ib_dev=${ib_dev}
server_ip=${server_ip}
client_ip=${client_ip}
duration_s=${GLM51_BW_DURATION}
base_port=${GLM51_BW_PORT}
EOF

run_test() {
  local bench="${1:?missing bench}"
  local label="${2:?missing label}"
  shift 2

  local port="${GLM51_BW_PORT}"
  case "${label}" in
    write_uni) port=$((GLM51_BW_PORT + 0)) ;;
    write_bi) port=$((GLM51_BW_PORT + 1)) ;;
    send_uni) port=$((GLM51_BW_PORT + 2)) ;;
    send_bi) port=$((GLM51_BW_PORT + 3)) ;;
  esac

  local server_log="${run_dir}/${label}.server.log"
  local client_log="${run_dir}/${label}.client.log"

  srun --overlap --jobid="${GLM51_JOB_ID}" -N1 -n1 -w "${server_node}" \
    bash --noprofile --norc -lc \
    "timeout $((GLM51_BW_DURATION + 20)) ${bench} -d '${ib_dev}' -i 1 -F --force-link=IB --report_gbits -D '${GLM51_BW_DURATION}' -p '${port}' $*" \
    >"${server_log}" 2>&1 &
  local server_pid=$!

  sleep 3

  if ! srun --overlap --jobid="${GLM51_JOB_ID}" -N1 -n1 -w "${client_node}" \
    bash --noprofile --norc -lc \
    "timeout $((GLM51_BW_DURATION + 20)) ${bench} '${server_ip}' -d '${ib_dev}' -i 1 -F --force-link=IB --report_gbits -D '${GLM51_BW_DURATION}' -p '${port}' $*" \
    >"${client_log}" 2>&1; then
    wait "${server_pid}" || true
    echo "glm51: ${label} failed; see ${client_log} and ${server_log}." >&2
    return 1
  fi

  wait "${server_pid}" || true
}

extract_bw_gbps() {
  local path="${1:?missing path}"
  awk '
    /^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9.]+[[:space:]]+[0-9.]+([[:space:]]+[0-9.]+)?[[:space:]]*$/ {
      val=$4
    }
    END {
      if (val == "") exit 1
      print val
    }
  ' "${path}"
}

run_test ib_write_bw write_uni
run_test ib_write_bw write_bi --bidirectional
run_test ib_send_bw send_uni
run_test ib_send_bw send_bi --bidirectional

summary_tsv="${run_dir}/summary.tsv"
printf 'test\tgbps\n' >"${summary_tsv}"
for label in write_uni write_bi send_uni send_bi; do
  bw="$(extract_bw_gbps "${run_dir}/${label}.client.log")"
  printf '%s\t%s\n' "${label}" "${bw}" >>"${summary_tsv}"
done

cat "${context_path}"
cat "${summary_tsv}"
