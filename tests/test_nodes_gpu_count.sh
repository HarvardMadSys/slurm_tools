#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fake scontrol serving a partition with a single mixed-GPU node (4 + 2 = 6 GPUs).
# ST_TEST_ALLOC controls how many GPUs AllocTRES reports as used.
mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/scontrol" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-} ${2:-}" == "show partition" ]]; then
  cat <<'P'
PartitionName=mixed
   State=UP
   Nodes=mnode1
P
elif [[ "${1:-} ${2:-}" == "show node" ]]; then
  alloc="AllocTRES="
  [[ "${ST_TEST_ALLOC:-0}" != "0" ]] && alloc="AllocTRES=gres/gpu=${ST_TEST_ALLOC}"
  cat <<NODE
NodeName=mnode1
   Gres=gpu:nvidia_h100_80gb_hbm3:4(S:0-3),gpu:nvidia_a40:2(S:4-5),holy8a_nodes:1
   ${alloc}
   CPUEfctv=16
   RealMemory=32768
   State=IDLE
NODE
else
  exit 1
fi
EOF
chmod +x "${TMP}/bin/scontrol"

run_nodes() { PATH="${TMP}/bin:${PATH}" "${ROOT}/libexec/nodes.sh" "$@"; }

# UnallocGPU column (field 2) must sum both GPU types: 4 + 2 = 6.
gpu_free="$(run_nodes -p mixed | awk '$1=="mnode1"{print $2}')"
[[ "$gpu_free" == "6" ]] || { echo "expected 6 unallocated GPUs, got '${gpu_free}'" >&2; exit 1; }

# With 5 of 6 GPUs allocated, UnallocGPU is 1 (the old first-entry-only parse
# produced 4 - 5 = -1).
gpu_free_alloc="$(ST_TEST_ALLOC=5 run_nodes -p mixed | awk '$1=="mnode1"{print $2}')"
[[ "$gpu_free_alloc" == "1" ]] || { echo "expected 1 unallocated GPU, got '${gpu_free_alloc}'" >&2; exit 1; }

printf 'nodes gpu-count tests passed\n'
