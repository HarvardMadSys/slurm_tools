#!/usr/bin/env bash
# Table of SLURM nodes in a partition (unallocated GPU / CPU / memory).
# Uses bash + awk over scontrol (no Python).
set -euo pipefail

usage() {
  cat <<EOF
usage: $(basename "$0") [--partition|-p NAME] [--available|-a] [--help|-h]

  -p PARTITION   Partition to query (default: SLURM_TOOLS_DEFAULT_PARTITION or gpu_requeue)
  -a             Include CPULoad and used-memory columns
EOF
}

PARTITION="${SLURM_TOOLS_DEFAULT_PARTITION:-gpu_requeue}"
SHOW_AVAILABLE="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p | --partition)
      PARTITION="${2:?}"
      shift 2
      ;;
    -a | --available)
      SHOW_AVAILABLE="1"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "$(basename "$0"): unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

NODE_LIST=""
while IFS= read -r line; do
  trimmed="${line#"${line%%[![:space:]]*}"}"
  [[ "$trimmed" == Nodes=* ]] || continue
  rest="${trimmed#Nodes=}"
  NODE_LIST="${rest%%[![:graph:]]*}"
  NODE_LIST="${NODE_LIST// }"
  break
done < <(scontrol show partition "$PARTITION")

if [[ -z "$NODE_LIST" ]]; then
  echo "$(basename "$0"): could not read Nodes= for partition: ${PARTITION}" >&2
  exit 1
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

scontrol show node "$NODE_LIST" >"$TMP"

tab=$'\t'

LC_ALL=C awk -v OFS="$tab" -v show_avail="$SHOW_AVAILABLE" '
BEGIN { RS = "\n\n" }

function val(line, key, klen, pos, rest) {
  klen = length(key)
  pos = index(line, key "=")
  if (pos == 0) return ""
  rest = substr(line, pos + klen + 1)
  sub(/[[:space:]].*$/, "", rest)
  return rest
}

function val_rest(line, key, klen, pos) {
  klen = length(key)
  pos = index(line, key "=")
  if (pos == 0) return ""
  return substr(line, pos + klen + 1)
}

function gpus_from_gres(g) {
  if (match(g, /:[0-9]+\(S:/))
    return substr(g, RSTART + 1, RLENGTH - 4) + 0
  if (match(g, /:[0-9]+$/))
    return substr(g, RSTART + 1, RLENGTH - 1) + 0
  return 0
}

length($0) == 0 { next }

{
  nm = ""; st = ""; gres = ""; alc = ""; load_s = ""
  efctv = rm = fm = 0

  nn = split($0, lines, /\n/)
  for (i = 1; i <= nn; i++) {
    ln = lines[i]; sub(/^[[:space:]]+/, "", ln)
    v = val(ln, "NodeName"); if (v != "") nm = v
    v = val(ln, "CPUEfctv"); if (v != "") efctv = v + 0
    if (show_avail) {
      v = val(ln, "CPULoad"); if (v != "") load_s = v
    }
    v = val(ln, "Gres"); if (v != "") gres = v
    v = val(ln, "RealMemory"); if (v != "") rm = v + 0
    if (show_avail) {
      v = val(ln, "FreeMem"); if (v != "") fm = v + 0
    }
    v = val(ln, "State"); if (v != "") st = v
    if (index(ln, "AllocTRES=") > 0) alc = val_rest(ln, "AllocTRES")
  }

  if (nm == "") next
  if (index(st, "DOWN") > 0) next

  ac = ag = amb = 0
  if (match(alc, /cpu=[0-9]+/)) {
    x = substr(alc, RSTART, RLENGTH); sub(/^cpu=/, "", x); ac = x + 0
  }
  if (match(alc, /gres\/gpu=[0-9]+/)) {
    x = substr(alc, RSTART, RLENGTH); sub(/^gres\/gpu=/, "", x); ag = x + 0
  }
  if (match(alc, /mem=[0-9]+[MG]?/)) {
    x = substr(alc, RSTART, RLENGTH); sub(/^mem=/, "", x)
    ut = substr(x, length(x), 1)
    if (ut == "G" || ut == "M") {
      vv = substr(x, 1, length(x) - 1) + 0
      amb = (ut == "G" ? vv * 1024 : vv)
    } else {
      amb = x + 0
    }
  }

  gpu_total = gpus_from_gres(gres)
  ugpu = gpu_total - ag
  ucpu = efctv - ac
  mem_gb_u = (rm - amb) / 1024
  cg = gres; sub(/^gpu:/, "", cg); gsub(/\([^)]*\)/, "", cg)

  if (show_avail) {
    used_gb = (rm - fm) / 1024
    load_v = load_s + 0
    printf "%d\t%d\t%.6f\t%s\t%d\t%d\t%.1f\t%.1f\t%.1f\t%s\t%s\t%s\n",
      ugpu, ucpu, used_gb, nm, ugpu, ucpu, mem_gb_u, load_v, used_gb, cg, st, alc
  } else {
    printf "%d\t%d\t%.6f\t%s\t%d\t%d\t%.1f\t%s\t%s\t%s\n",
      ugpu, ucpu, mem_gb_u, nm, ugpu, ucpu, mem_gb_u, cg, st, alc
  }
}
' "$TMP" | LC_ALL=C sort -t "$tab" -k1,1nr -k2,2nr -k3,3n | awk -F "$tab" -v show_avail="$SHOW_AVAILABLE" '
BEGIN {
  if (show_avail) {
    printf("%-20s %-10s %-10s %-14s %-8s %-11s %-25s %-15s %s\n",
      "NodeName", "UnallocGPU", "UnallocCPU", "UnallocMem(GB)", "CPULoad", "UsedMem(GB)", "Gres", "State", "AllocTRES")
    printf("%-20s %-10s %-10s %-14s %-8s %-11s %-25s %-15s %s\n",
      "--------", "----------", "----------", "--------------", "--------", "-----------", "-------------------------",
      "---------------", "-----------")
  } else {
    printf("%-20s %-10s %-10s %-14s %-25s %-15s %s\n",
      "NodeName", "UnallocGPU", "UnallocCPU", "UnallocMem(GB)", "Gres", "State", "AllocTRES")
    printf("%-20s %-10s %-10s %-14s %-25s %-15s %s\n",
      "--------", "----------", "----------", "--------------", "-------------------------",
      "---------------", "-----------")
  }
}
show_avail {
  printf("%-20s %-10s %-10s %-14s %-8s %-11s %-25s %-15s %s\n", $4, $5, $6, $7, $8, $9, $10, $11, $12)
  next
}
{
  printf("%-20s %-10s %-10s %-14s %-25s %-15s %s\n", $4, $5, $6, $7, $8, $9, $10)
}'
