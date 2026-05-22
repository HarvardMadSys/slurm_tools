#!/usr/bin/env bash
# Table of SLURM nodes in a partition (unallocated GPU / CPU / memory).
# Uses bash + awk over scontrol (no Python).
set -euo pipefail

usage() {
  cat <<EOF
usage: $(basename "$0") [--partition|-p NAME] [--available|-a] [--help|-h]

  -p PARTITION   Partition to query (default: gpu_requeue)
  -a             Include CPULoad and used-memory columns
EOF
}

PARTITION="gpu_requeue"
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
  [[ "$trimmed" == Nodes=* ]] || [[ "$trimmed" == *Nodes=* ]] || continue
  if [[ "$trimmed" == Nodes=* ]]; then
    rest="${trimmed#Nodes=}"
  else
    rest="${trimmed#*Nodes=}"
  fi
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

if [[ "$SHOW_AVAILABLE" == "1" ]]; then
  LC_ALL=C awk -v OFS="$tab" '
BEGIN { RS = "\n\n" }

function field(line, key, klen, rest) {
  klen = length(key)
  if (substr(line, 1, klen + 1) != key "=") return ""
  rest = substr(line, klen + 2)
  sub(/^[[:space:]]+/, "", rest)
  sub(/[[:space:]].*$/, "", rest)
  return rest
}

function full_after_key(line, key, klen) {
  klen = length(key)
  if (substr(line, 1, klen + 1) != key "=") return ""
  return substr(line, index(line, "=") + 1)
}

length($0) == 0 { next }

{
  nm = ""; st = ""; gres = ""; alc = ""; load_s = ""
  efctv = rm = fm = 0

  nn = split($0, lines, /\n/)
  for (i = 1; i <= nn; i++) {
    ln = lines[i]; sub(/^[[:space:]]+/, "", ln)
    if (substr(ln, 1, 10) == "NodeName=") nm = field(ln, "NodeName")
    else if (substr(ln, 1, 10) == "CPUEfctv=") efctv = field(ln, "CPUEfctv") + 0
    else if (substr(ln, 1, 9) == "CPULoad=") load_s = field(ln, "CPULoad")
    else if (substr(ln, 1, 5) == "Gres=") gres = field(ln, "Gres")
    else if (substr(ln, 1, 13) == "RealMemory=") rm = field(ln, "RealMemory") + 0
    else if (substr(ln, 1, 8) == "FreeMem=") fm = field(ln, "FreeMem") + 0
    else if (substr(ln, 1, 7) == "State=") st = field(ln, "State")
    else if (substr(ln, 1, 11) == "AllocTRES=") alc = full_after_key(ln, "AllocTRES")
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

  gpu_total = 0
  if (gres ~ /nvidia/ && match(gres, /:[0-9]+$/))
    gpu_total = substr(gres, RSTART + 1, RLENGTH - 1) + 0

  ugpu = gpu_total - ag
  ucpu = efctv - ac
  mem_gb_u = (rm - amb) / 1024
  used_gb = (rm - fm) / 1024
  load_v = load_s + 0

  cg = gres; sub(/^gpu:/, "", cg); gsub(/\([^)]*\)/, "", cg)

  printf "%d\t%d\t%.6f\t%s\t%d\t%d\t%.1f\t%.1f\t%.1f\t%s\t%s\t%s\n",
    ugpu, ucpu, used_gb, nm, ugpu, ucpu, mem_gb_u, load_v, used_gb, cg, st, alc
}
' "$TMP" | LC_ALL=C sort -t "$tab" -k1,1nr -k2,2nr -k3,3n | awk -F "$tab" 'BEGIN {
  printf("%-20s %-10s %-10s %-14s %-8s %-11s %-25s %-15s %s\n",
    "NodeName", "UnallocGPU", "UnallocCPU", "UnallocMem(GB)", "CPULoad", "UsedMem(GB)", "Gres", "State", "AllocTRES")
  printf("%-20s %-10s %-10s %-14s %-8s %-11s %-25s %-15s %s\n",
    "--------", "----------", "----------", "--------------", "--------", "-----------", "-------------------------",
    "---------------", "-----------")
}
{ printf("%-20s %-10s %-10s %-14s %-8s %-11s %-25s %-15s %s\n", $4, $5, $6, $7, $8, $9, $10, $11, $12) }'
else
  LC_ALL=C awk -v OFS="$tab" '
BEGIN { RS = "\n\n" }

function field(line, key, klen, rest) {
  klen = length(key)
  if (substr(line, 1, klen + 1) != key "=") return ""
  rest = substr(line, klen + 2)
  sub(/^[[:space:]]+/, "", rest)
  sub(/[[:space:]].*$/, "", rest)
  return rest
}

function full_after_key(line, key, klen) {
  klen = length(key)
  if (substr(line, 1, klen + 1) != key "=") return ""
  return substr(line, index(line, "=") + 1)
}

length($0) == 0 { next }

{
  nm = ""; st = ""; gres = ""; alc = ""
  efctv = rm = fm = 0

  nn = split($0, lines, /\n/)
  for (i = 1; i <= nn; i++) {
    ln = lines[i]; sub(/^[[:space:]]+/, "", ln)
    if (substr(ln, 1, 10) == "NodeName=") nm = field(ln, "NodeName")
    else if (substr(ln, 1, 10) == "CPUEfctv=") efctv = field(ln, "CPUEfctv") + 0
    else if (substr(ln, 1, 5) == "Gres=") gres = field(ln, "Gres")
    else if (substr(ln, 1, 13) == "RealMemory=") rm = field(ln, "RealMemory") + 0
    else if (substr(ln, 1, 8) == "FreeMem=") fm = field(ln, "FreeMem") + 0
    else if (substr(ln, 1, 7) == "State=") st = field(ln, "State")
    else if (substr(ln, 1, 11) == "AllocTRES=") alc = full_after_key(ln, "AllocTRES")
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

  gpu_total = 0
  if (gres ~ /nvidia/ && match(gres, /:[0-9]+$/))
    gpu_total = substr(gres, RSTART + 1, RLENGTH - 1) + 0

  ugpu = gpu_total - ag
  ucpu = efctv - ac
  mem_gb_u = (rm - amb) / 1024

  cg = gres; sub(/^gpu:/, "", cg); gsub(/\([^)]*\)/, "", cg)

  printf "%d\t%d\t%.6f\t%s\t%d\t%d\t%.1f\t%s\t%s\t%s\n",
    ugpu, ucpu, mem_gb_u, nm, ugpu, ucpu, mem_gb_u, cg, st, alc
}
' "$TMP" | LC_ALL=C sort -t "$tab" -k1,1nr -k2,2nr -k3,3nr | awk -F "$tab" 'BEGIN {
  printf("%-20s %-10s %-10s %-14s %-25s %-15s %s\n",
    "NodeName", "UnallocGPU", "UnallocCPU", "UnallocMem(GB)", "Gres", "State", "AllocTRES")
  printf("%-20s %-10s %-10s %-14s %-25s %-15s %s\n",
    "--------", "----------", "----------", "--------------", "-------------------------",
    "---------------", "-----------")
}
{ printf("%-20s %-10s %-10s %-14s %-25s %-15s %s\n", $4, $5, $6, $7, $8, $9, $10) }'
fi
