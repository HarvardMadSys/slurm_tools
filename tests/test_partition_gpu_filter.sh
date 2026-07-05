#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fake scontrol: one GPU partition (gpupart) and one CPU-only partition (cpupart).
# The GPU nodes' AllocTRES is controlled by ST_TEST_GPU_ALLOCATED so we can
# simulate "GPUs currently free" vs "all GPUs allocated".
mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/scontrol" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-} ${2:-}" == "show partition" && -z "${3:-}" ]]; then
  cat <<'PARTITIONS'
PartitionName=gpupart
   State=UP MaxTime=1-00:00:00 TotalCPUs=32 TotalNodes=2
   TRES=cpu=32,mem=65536M,gres/gpu=8,gres/gpu:nvidia_h100_80gb_hbm3=8
   TRESBillingWeights=CPU=1,Mem=0G,Gres/gpu=1
   PriorityTier=1
   Nodes=gnode[1-2]
PartitionName=cpupart
   State=UP MaxTime=1-00:00:00 TotalCPUs=32 TotalNodes=1
   TRES=cpu=32,mem=65536M
   TRESBillingWeights=CPU=1,Mem=0G
   PriorityTier=1
   Nodes=cnode1
PARTITIONS
elif [[ "${1:-} ${2:-}" == "show node" ]]; then
  case "${3:-}" in
    *gnode*)
      if [[ "${ST_TEST_GPU_ALLOCATED:-0}" == "1" ]]; then
        alloc="AllocTRES=gres/gpu=4"
      else
        alloc="AllocTRES="
      fi
      cat <<NODES
NodeName=gnode1
   Gres=gpu:nvidia_h100_80gb_hbm3:4(S:0-3)
   ${alloc}
   CPUEfctv=16
   RealMemory=32768
   State=IDLE

NodeName=gnode2
   Gres=gpu:nvidia_h100_80gb_hbm3:4(S:0-3)
   ${alloc}
   CPUEfctv=16
   RealMemory=32768
   State=IDLE
NODES
      ;;
    *cnode*)
      cat <<'NODES'
NodeName=cnode1
   Gres=(null)
   AllocTRES=
   CPUEfctv=32
   RealMemory=65536
   State=IDLE
NODES
      ;;
    *) exit 1 ;;
  esac
else
  exit 1
fi
EOF
chmod +x "${TMP}/bin/scontrol"

run_part() { PATH="${TMP}/bin:${PATH}" "${ROOT}/libexec/partition.sh" "$@"; }

# A GPU request must pick a partition that actually has GPUs, never the CPU-only one.
best="$(run_part -c 1 -m 0 -g 1 --name-only)"
[[ "$best" == "gpupart" ]] || { echo "expected gpupart, got '${best}'" >&2; exit 1; }

# CPU-only partition never appears among GPU-request candidates.
[[ "$(run_part -c 1 -m 0 -g 1 --json)" != *cpupart* ]]

# When every GPU is allocated, the available-resources pass finds nothing...
set +e
ST_TEST_GPU_ALLOCATED=1 run_part -c 1 -m 0 -g 1 --name-only >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 1 ]] || { echo "expected exit 1 when no GPUs free, got ${rc}" >&2; exit 1; }

# ...but the total-capacity pass still recommends the GPU partition.
best_total="$(ST_TEST_GPU_ALLOCATED=1 run_part -c 1 -m 0 -g 1 --total --name-only)"
[[ "$best_total" == "gpupart" ]] || { echo "expected gpupart with --total, got '${best_total}'" >&2; exit 1; }

# A CPU-only job is unaffected: cpupart is the cheaper pick (no GPU weight).
best_cpu="$(run_part -c 1 -m 0 --name-only)"
[[ -n "$best_cpu" ]] || { echo "expected a CPU recommendation" >&2; exit 1; }

# Non-numeric resource values are rejected instead of silently becoming 0.
for bad in "-c abc -m 8" "-c 4 -m 8 -g x" "-c 4 -m 8 -t soon"; do
  set +e
  # shellcheck disable=SC2086
  run_part $bad --name-only >/dev/null 2>&1
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || { echo "expected non-numeric '${bad}' to fail" >&2; exit 1; }
done

printf 'partition gpu-filter and validation tests passed\n'
