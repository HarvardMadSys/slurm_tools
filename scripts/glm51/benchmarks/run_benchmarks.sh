#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
glm51_dir="$(cd "${script_dir}/.." && pwd)"

# shellcheck source=../common.sh
source "${glm51_dir}/common.sh"

glm51_check_parallelism
glm51_require_model

BACKENDS_STRING="${GLM51_BACKENDS:-vllm sglang}"
CONFIGS_STRING="${GLM51_CONFIGS:-8:1 4:2 2:4 1:8}"
PREFILL_LENS_STRING="${GLM51_PREFILL_LENGTHS:-1024 2048 4096 8192 16384 32768 65536 131072}"
DECODE_BATCHES_STRING="${GLM51_DECODE_BATCHES:-1 2 4 8 16 32 64 128}"

read -r -a BACKENDS <<< "${BACKENDS_STRING}"
read -r -a CONFIGS <<< "${CONFIGS_STRING}"
read -r -a PREFILL_LENS <<< "${PREFILL_LENS_STRING}"
read -r -a DECODE_BATCHES <<< "${DECODE_BATCHES_STRING}"

reverse_values() {
  local values=("$@")
  local idx
  for ((idx=${#values[@]}-1; idx>=0; --idx)); do
    printf '%s\n' "${values[idx]}"
  done
}

mapfile -t PREFILL_LENS_RUN < <(reverse_values "${PREFILL_LENS[@]}")
mapfile -t DECODE_BATCHES_RUN < <(reverse_values "${DECODE_BATCHES[@]}")

RUN_ID="${GLM51_RUN_ID:-$(glm51_timestamp)}"
RUN_ROOT="${GLM51_RESULTS_DIR}/${RUN_ID}"
mkdir -p "${RUN_ROOT}"

SUMMARY_TXT="${RUN_ROOT}/summary.txt"
FAILURES_TSV="${RUN_ROOT}/failures.tsv"
STATUS_TSV="${RUN_ROOT}/status.tsv"

if [[ ! -f "${FAILURES_TSV}" ]]; then
  printf 'backend\ttopology\tstage\treason\n' > "${FAILURES_TSV}"
fi
if [[ ! -f "${STATUS_TSV}" ]]; then
  printf 'backend\ttopology\tresult\n' > "${STATUS_TSV}"
fi

run_head_cmd() {
  local logfile="${1:?missing logfile}"
  shift
  local quoted
  quoted="$(printf '%q ' "$@")"
  srun --overlap --jobid="${GLM51_JOB_ID}" -N1 -n1 -w "${GLM51_HEAD_NODE}" \
    bash --noprofile --norc -lc "
      export HF_HOME='${HF_HOME}'
      export HUGGINGFACE_HUB_CACHE='${HUGGINGFACE_HUB_CACHE}'
      export HF_HUB_CACHE='${HF_HUB_CACHE}'
      export TRANSFORMERS_CACHE='${TRANSFORMERS_CACHE}'
      ${quoted}
    " >"${logfile}" 2>&1
}

record_failure() {
  local backend="${1:?missing backend}"
  local topology="${2:?missing topology}"
  local stage="${3:?missing stage}"
  local reason="${4:?missing reason}"
  printf '%s\t%s\t%s\t%s\n' "${backend}" "${topology}" "${stage}" "${reason}" >> "${FAILURES_TSV}"
}

record_status() {
  local backend="${1:?missing backend}"
  local topology="${2:?missing topology}"
  local result="${3:?missing result}"
  printf '%s\t%s\t%s\n' "${backend}" "${topology}" "${result}" >> "${STATUS_TSV}"
}

case_already_failed() {
  local backend="${1:?missing backend}"
  local topology="${2:?missing topology}"
  local stage="${3:?missing stage}"
  [[ -f "${FAILURES_TSV}" ]] || return 1
  awk -F '\t' -v backend="${backend}" -v topology="${topology}" -v stage="${stage}" '
    $1 == backend && $2 == topology && $3 == stage { found=1 }
    END { exit(found ? 0 : 1) }
  ' "${FAILURES_TSV}"
}

jsonl_has_case() {
  local jsonl="${1:?missing jsonl}"
  local key="${2:?missing key}"
  local value="${3:?missing value}"
  [[ -f "${jsonl}" ]] || return 1
  "${GLM51_PYTHON}" - "${jsonl}" "${key}" "${value}" <<'PY'
import json
import sys

path, key, value = sys.argv[1:4]
try:
    target = int(value)
except ValueError:
    target = value

with open(path) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if row.get(key) == target:
            raise SystemExit(0)

raise SystemExit(1)
PY
}

launch_backend() {
  local backend="${1:?missing backend}"
  local run_dir="${2:?missing run_dir}"
  local stage="${3:?missing stage}"
  local launch_log="${run_dir}/launch.${stage}.stdout.log"

  "${glm51_dir}/stop.sh" >"${run_dir}/stop_before_${stage}.log" 2>&1 || true
  if ! "${glm51_dir}/launch_${backend}.sh" >"${launch_log}" 2>&1; then
    record_failure "${backend}" "${topology}" "launch_${stage}" "see ${launch_log}"
    "${glm51_dir}/stop.sh" >"${run_dir}/stop_after_failed_launch_${stage}.log" 2>&1 || true
    return 1
  fi
  return 0
}

stop_backend() {
  local run_dir="${1:?missing run_dir}"
  local stage="${2:?missing stage}"
  "${glm51_dir}/stop.sh" >"${run_dir}/stop_after_${stage}.log" 2>&1 || true
}

run_prefill_case() {
  local backend="${1:?missing backend}"
  local topology="${2:?missing topology}"
  local run_dir="${3:?missing run_dir}"
  local prefill_jsonl="${4:?missing prefill jsonl}"
  local input_len="${5:?missing input len}"
  local warmup_requests="${6:-1}"
  local case_log="${run_dir}/prefill_len${input_len}.stdout.log"

  run_head_cmd "${case_log}" \
    timeout "${GLM51_BENCH_CASE_TIMEOUT}" \
    "${GLM51_PYTHON}" "${script_dir}/bench_http.py" \
    --backend "${backend}" \
    --base-url "http://127.0.0.1:${GLM51_SERVE_PORT}" \
    --model-path "${GLM51_MODEL}" \
    --run-name "${backend}_${topology}_prefill" \
    --batch-size 1 \
    --input-len "${input_len}" \
    --output-len 1 \
    --request-timeout "${GLM51_BENCH_CASE_TIMEOUT}" \
    --warmup-requests "${warmup_requests}" \
    --result-filename "${prefill_jsonl}"
}

run_decode_case() {
  local backend="${1:?missing backend}"
  local topology="${2:?missing topology}"
  local run_dir="${3:?missing run_dir}"
  local decode_jsonl="${4:?missing decode jsonl}"
  local batch_size="${5:?missing batch size}"
  local warmup_requests="${6:-1}"
  local case_log="${run_dir}/decode_bs${batch_size}.stdout.log"

  run_head_cmd "${case_log}" \
    timeout "${GLM51_BENCH_CASE_TIMEOUT}" \
    "${GLM51_PYTHON}" "${script_dir}/bench_http.py" \
    --backend "${backend}" \
    --base-url "http://127.0.0.1:${GLM51_SERVE_PORT}" \
    --model-path "${GLM51_MODEL}" \
    --run-name "${backend}_${topology}_decode" \
    --batch-size "${batch_size}" \
    --input-len 16 \
    --output-len 128 \
    --request-timeout "${GLM51_BENCH_CASE_TIMEOUT}" \
    --warmup-requests "${warmup_requests}" \
    --result-filename "${decode_jsonl}"
}

run_prefill_matrix() {
  local backend="${1:?missing backend}"
  local topology="${2:?missing topology}"
  local run_dir="${3:?missing run dir}"
  local prefill_jsonl="${4:?missing prefill jsonl}"
  local launched=0
  local just_launched=0
  local input_len
  local attempt
  local warmup_requests

  for input_len in "${PREFILL_LENS_RUN[@]}"; do
    if case_already_failed "${backend}" "${topology}" "prefill_len${input_len}"; then
      echo "skip known failed prefill input_len=${input_len}" | tee -a "${SUMMARY_TXT}"
      continue
    fi
    if jsonl_has_case "${prefill_jsonl}" "input_len" "${input_len}"; then
      echo "skip existing prefill input_len=${input_len}" | tee -a "${SUMMARY_TXT}"
      continue
    fi
    if (( launched == 0 )); then
      if ! launch_backend "${backend}" "${run_dir}" "prefill"; then
        return 1
      fi
      launched=1
      just_launched=1
    fi
    for attempt in 1 2; do
      if (( just_launched == 1 )); then
        warmup_requests=2
      else
        warmup_requests=1
      fi
      echo "prefill backend=${backend} topology=${topology} input_len=${input_len} attempt=${attempt}" | tee -a "${SUMMARY_TXT}"
      if run_prefill_case "${backend}" "${topology}" "${run_dir}" "${prefill_jsonl}" "${input_len}" "${warmup_requests}"; then
        just_launched=0
        break
      fi
      just_launched=0
      stop_backend "${run_dir}" "prefill"
      launched=0
      if (( attempt == 1 )); then
        if ! launch_backend "${backend}" "${run_dir}" "prefill_retry"; then
          return 1
        fi
        launched=1
        just_launched=1
        continue
      fi
      record_failure "${backend}" "${topology}" "prefill_len${input_len}" "see ${run_dir}/prefill_len${input_len}.stdout.log"
    done
  done

  if (( launched == 1 )); then
    stop_backend "${run_dir}" "prefill"
  fi
  return 0
}

run_decode_matrix() {
  local backend="${1:?missing backend}"
  local topology="${2:?missing topology}"
  local run_dir="${3:?missing run dir}"
  local decode_jsonl="${4:?missing decode jsonl}"
  local launched=0
  local just_launched=0
  local batch_size
  local attempt
  local warmup_requests

  for batch_size in "${DECODE_BATCHES_RUN[@]}"; do
    if case_already_failed "${backend}" "${topology}" "decode_bs${batch_size}"; then
      echo "skip known failed decode batch_size=${batch_size}" | tee -a "${SUMMARY_TXT}"
      continue
    fi
    if jsonl_has_case "${decode_jsonl}" "batch_size" "${batch_size}"; then
      echo "skip existing decode batch_size=${batch_size}" | tee -a "${SUMMARY_TXT}"
      continue
    fi
    if (( launched == 0 )); then
      if ! launch_backend "${backend}" "${run_dir}" "decode"; then
        return 1
      fi
      launched=1
      just_launched=1
    fi
    for attempt in 1 2; do
      if (( just_launched == 1 )); then
        warmup_requests=2
      else
        warmup_requests=1
      fi
      echo "decode backend=${backend} topology=${topology} batch_size=${batch_size} attempt=${attempt}" | tee -a "${SUMMARY_TXT}"
      if run_decode_case "${backend}" "${topology}" "${run_dir}" "${decode_jsonl}" "${batch_size}" "${warmup_requests}"; then
        just_launched=0
        break
      fi
      just_launched=0
      stop_backend "${run_dir}" "decode"
      launched=0
      if (( attempt == 1 )); then
        if ! launch_backend "${backend}" "${run_dir}" "decode_retry"; then
          return 1
        fi
        launched=1
        just_launched=1
        continue
      fi
      record_failure "${backend}" "${topology}" "decode_bs${batch_size}" "see ${run_dir}/decode_bs${batch_size}.stdout.log"
    done
  done

  if (( launched == 1 )); then
    stop_backend "${run_dir}" "decode"
  fi
  return 0
}

echo "run_root=${RUN_ROOT}"
echo "$(glm51_print_context)" | tee "${RUN_ROOT}/context.txt"

run_idx=0
for backend in "${BACKENDS[@]}"; do
  for cfg in "${CONFIGS[@]}"; do
    ((run_idx += 1))
    export GLM51_TP="${cfg%%:*}"
    export GLM51_PP="${cfg##*:}"
    export GLM51_DIST_PORT="$((29500 + run_idx))"
    export GLM51_RAY_PORT="$((6379 + run_idx))"
    export GLM51_SERVE_PORT="$((30000 + run_idx))"
    glm51_check_parallelism

    topology="$(glm51_parallelism_label)"
    run_dir="${RUN_ROOT}/${backend}_${topology}"
    mkdir -p "${run_dir}"

    prefill_jsonl="${run_dir}/prefill.jsonl"
    decode_jsonl="${run_dir}/decode.jsonl"
    touch "${prefill_jsonl}" "${decode_jsonl}"

    echo "=== backend=${backend} topology=${topology} ===" | tee -a "${SUMMARY_TXT}"
    echo "$(glm51_print_context)" > "${run_dir}/context.txt"

    record_status "${backend}" "${topology}" "start"

    if ! run_prefill_matrix "${backend}" "${topology}" "${run_dir}" "${prefill_jsonl}"; then
      record_status "${backend}" "${topology}" "prefill_launch_failed"
    fi

    if ! run_decode_matrix "${backend}" "${topology}" "${run_dir}" "${decode_jsonl}"; then
      record_status "${backend}" "${topology}" "decode_launch_failed"
    fi

    "${glm51_dir}/stop.sh" >"${run_dir}/stop_final.log" 2>&1 || true
    record_status "${backend}" "${topology}" "finished"
  done
done

"${GLM51_PYTHON}" "${script_dir}/summarize_results.py" "${RUN_ROOT}" | tee -a "${SUMMARY_TXT}"
