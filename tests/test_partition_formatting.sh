#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/scontrol" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1 $2" == "show partition" ]]; then
  cat <<'PARTITIONS'
PartitionName=precise
   State=UP MaxTime=1-00:00:00 TotalCPUs=16 TotalNodes=2
   TRES=cpu=16,mem=32768M,gres/gpu=8
   TRESBillingWeights=CPU=1.003,Mem=0G,Gres/gpu=0
   PriorityTier=9
   Nodes=precise[1-2]
PartitionName=rounded
   State=UP MaxTime=1-00:00:00 TotalCPUs=16 TotalNodes=2
   TRES=cpu=16,mem=32768M,gres/gpu=8
   TRESBillingWeights=CPU=1.004,Mem=0G,Gres/gpu=0
   PriorityTier=1
   Nodes=rounded[1-2]
PARTITIONS
elif [[ "$1 $2" == "show node" ]]; then
  cat <<'NODES'
NodeName=node1
   Gres=gpu:nvidia_h100_80gb_hbm3:4(S:0-3)
   AllocTRES=
   CPUEfctv=8
   RealMemory=16384
   State=IDLE

NodeName=node2
   Gres=gpu:nvidia_h100_80gb_hbm3:4(S:0-3),gpu:nvidia_a40:2(S:4-5),holy8a_nodes:1
   AllocTRES=
   CPUEfctv=8
   RealMemory=16384
   State=IDLE
NODES
else
  exit 1
fi
EOF
chmod +x "${TMP}/bin/scontrol"

output="$(PATH="${TMP}/bin:${PATH}" "${ROOT}/libexec/partition.sh" -c 1 -m 0)"

# Ranking continues to use unrounded costs, while displayed costs use at most
# two decimal places.
expected_header="Rank  Partition            Cost     Max Time        Priority  Available resources"
expected_first="1     precise              1        1-00:00:00      9         16 CPUs, 32 GB, 10 GPUs, (2 GPU types)"
expected_second="2     rounded              1        1-00:00:00      1         16 CPUs, 32 GB, 10 GPUs, (2 GPU types)"
[[ "$output" == *"$expected_header"* ]]
[[ "$output" == *"$expected_first"* ]]
[[ "$output" == *"$expected_second"* ]]
[[ "$output" == *$'Best recommendation: precise\n   Cost: 1 billing units'* ]]
[[ "$output" != *"1.003000000000"* ]]

# Mixed GPU metadata and non-GPU GRES values do not make resource rows grow
# with the node count.
[[ "$(grep -o '2 GPU types' <<<"$output" | wc -l)" -eq 2 ]]
[[ "$output" != *"holy8a_nodes"* ]]
while IFS= read -r row; do
  [[ "${#row}" -le 120 ]]
done < <(grep '^[0-9]' <<<"$output")

json_output="$(PATH="${TMP}/bin:${PATH}" "${ROOT}/libexec/partition.sh" -c 10 -m 0 --total --json)"
python3 -c '
import json
import sys

partitions = json.load(sys.stdin)
assert partitions[0]["cost"] == 10.03
assert partitions[1]["cost"] == 10.04
' <<<"$json_output"

printf 'partition formatting tests passed\n'
