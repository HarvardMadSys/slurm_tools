#!/usr/bin/env bash
# Recommend a SLURM partition (bash + awk over scontrol; no Python).
set -euo pipefail

usage() {
  cat <<'EOF'
usage: best_partition [--cpu|-c N] [--mem|-m GB] [--gpu|-g N] [--time|-t HOURS]
                      [--summary|-s] [--json|-j] [--name-only|-n]
                      [--total-resources|--tr] [--gpu-type STR] [--gpu-memory STR]

Requires --cpu and --mem unless --summary.
EOF
}

abort() { printf "%s\n" "$*" >&2; exit 1; }

quiet() { [[ "$NAMEONLY" == "1" ]] && return 0; printf "%s\n" "$*"; }

CPU=""; MEM=""; GPU=0; TIME=""; SUMMARY=0; JSON_OUT=0; NAMEONLY=0; TOTAL_RES=0; GPUTYPE=""; GPUMEM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --cpu=* ) CPU="${1#*=}"; shift ;;
    -c|--cpu) CPU="${2:?}"; shift 2 ;;
    --mem=* ) MEM="${1#*=}"; shift ;;
    -m|--mem) MEM="${2:?}"; shift 2 ;;
    --gpu=* ) GPU="${1#*=}"; shift ;;
    -g|--gpu) GPU="${2:?}"; shift 2 ;;
    --time=* ) TIME="${1#*=}"; shift ;;
    -t|--time) TIME="${2:?}"; shift 2 ;;
    -s|--summary) SUMMARY=1; shift ;;
    -j|--json) JSON_OUT=1; shift ;;
    -n|--name-only) NAMEONLY=1; shift ;;
    --total-resources|--tr) TOTAL_RES=1; shift ;;
    --gpu-type=* ) GPUTYPE="${1#*=}"; shift ;;
    --gpu-type) GPUTYPE="${2:?}"; shift 2 ;;
    --gpu-memory=* ) GPUMEM="${1#*=}"; shift ;;
    --gpu-memory) GPUMEM="${2:?}"; shift 2 ;;
    *) abort "unknown argument: $1" ;;
  esac
done

HAVE_AVAIL=1; [[ "$TOTAL_RES" == "1" ]] && HAVE_AVAIL=0

if [[ "$SUMMARY" != "1" ]]; then
  [[ -n "${CPU:-}" && -n "${MEM:-}" ]] || abort "Error: --cpu and --mem are required unless using --summary"
fi

nodes_line_for_partition() {
  local trimmed rest
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [[ "$trimmed" == Nodes=* ]] || [[ "$trimmed" == *Nodes=* ]] || continue
    if [[ "$trimmed" == Nodes=* ]]; then rest="${trimmed#Nodes=}"; else rest="${trimmed#*Nodes=}"; fi
    printf "%s\n" "${rest%%[![:graph:]]*}"; return 0
  done < <(scontrol show partition "$1")
  return 1
}

avail_and_blob_stream() {
  LC_ALL=C awk '
  BEGIN { RS = "\n\n"; blob = ""; cpus = amb = gpu = 0 }
  length($0) == 0 { next }
  {
    gn = split($0, L, /\n/)
    st = ""; alc = ""; efctv = 0; rmem = 0; gres = ""; down = 0
    for (i = 1; i <= gn; i++) {
      ln = L[i]; sub(/^[[:space:]]+/, "", ln)
      if (substr(ln, 1, 7) == "State=") st = fv(ln)
      if (index(st, "DOWN")) down = 1
      if (substr(ln, 1, 10) == "AllocTRES=") alc = fv_all(ln)
      if (substr(ln, 1, 10) == "CPUEfctv=") efctv = fvnum(ln)
      if (substr(ln, 1, 13) == "RealMemory=") rmem = fvnum(ln)
      if (substr(ln, 1, 5) == "Gres=") gres = fv(ln)
    }
    if (down) next
    ac = ag = mb = 0
    if (match(alc, /cpu=[0-9]+/)) { x = substr(alc, RSTART + 4, RLENGTH - 4); ac = x + 0 }
    if (match(alc, /gres\/gpu=[0-9]+/)) { x = substr(alc, RSTART + 9, RLENGTH - 9); ag = x + 0 }
    if (match(alc, /mem=[0-9]+[MG]?/)) {
      x = substr(alc, RSTART + 4, RLENGTH - 4)
      ut = substr(x, length(x), 1)
      if (ut == "G" || ut == "M") {
        vv = substr(x, 1, length(x) - 1) + 0
        mb = (ut == "G" ? vv * 1024 : vv)
      } else mb = x + 0
    }
    node_gpus = 0
    if (gres ~ /nvidia/ && match(gres, /:[0-9]+$/)) node_gpus = substr(gres, RSTART + 1, RLENGTH - 1) + 0
    cpus += ((efctv - ac) >= 0 ? efctv - ac : 0)
    amb += ((rmem - mb) >= 0 ? rmem - mb : 0)
    gpu += ((node_gpus - ag) >= 0 ? node_gpus - ag : 0)
    cg = gres; sub(/^gpu:/, "", cg); gsub(/\([^)]*\)/, "", cg)
    if (length(cg) > 0) { sep = blob == "" ? "" : " "; blob = blob sep tolower(cg) }
  }
  END { printf ("%s|%d|%d|%d\n", blob, cpus, amb, gpu) }
  function fv(line, idx, tail) {
    idx = index(line, "="); if (!idx) return ""
    tail = substr(line, idx + 1)
    sub(/^[[:space:]]+/, "", tail); sub(/[[:space:]].*$/, "", tail)
    return tail
  }
  function fv_all(line, idx){ idx = index(line, "="); if (!idx) return ""; return substr(line, idx + 1) }
  function fvnum(line){ return fv(line)+0 }
  '
}

partition_minutes() {
  LC_ALL=C awk -v mt="$1" '
  BEGIN {
    if (mt == "UNLIMITED" || mt == "") { print 999999999; exit }
    gsub(/^ +/, "", mt); gsub(/ +$/, "", mt)
    days = 0; rest = mt
    if (index(mt, "-") && match(mt, /^[0-9]+-/)) {
      days = substr(mt, RSTART, RLENGTH-1) + 0
      rest = substr(mt, RSTART + RLENGTH)
    }
    n = split(rest, tp, ":")
    h = m = s = 0
    if (n == 3) { h = tp[1] + 0; m = tp[2] + 0; s = tp[3] + 0 }
    else if (n == 2) { h = tp[1] + 0; m = tp[2] + 0; s = 0 }
    else if (n == 1) { h = tp[1] + 0; m = s = 0 }
    mins = days*24*60 + h*60 + m
    mins += ((s>=30)?1:0)
    print mins
  }'
}

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

RAW="$(mktemp)"; ENR="$(mktemp)"; CANDS="$(mktemp)"
trap 'rm -f "$RAW" "$ENR" "$CANDS"' EXIT

quiet "Fetching partition information..."
scontrol show partition >"$RAW"

split_prog="$(mktemp)"
trap 'rm -f "$RAW" "$ENR" "$CANDS" "$split_prog"' EXIT
cat <<'AWK' >"$split_prog"
function fv(line, idx,tail){ idx=index(line,"="); if(!idx)return""; tail=substr(line,idx+1); sub(/^[[:space:]]+/,"",tail); sub(/[[:space:]].*$/,"",tail); return tail}
function fv_all(line,idx){ idx=index(line,"="); if(!idx)return""; return substr(line,idx+1)}
function fvnum(line){ return fv(line)+0 }
function emit(blk){
  gn=split(blk,LL,/\n/)
  nm=""; maxt="UNLIMITED"; tres=""; wt=""; st=""; prio=0
  tcpus=tnodes=tmem=tgpu=0
  for(j=1;j<=gn;j++){
    ln=LL[j]; sub(/^[[:space:]]+/, "", ln)
    if(ln=="") continue
    if(substr(ln,1,15)=="PartitionName=") nm=fv(ln)
    else if(substr(ln,1,8)=="MaxTime=") maxt=fv(ln)
    else if(substr(ln,1,11)=="TotalCPUs=") tcpus=fvnum(ln)
    else if(substr(ln,1,12)=="TotalNodes=") tnodes=fvnum(ln)
    else if(substr(ln,1,5)=="TRES=") tres=fv_all(ln)
    else if(substr(ln,1,20)=="TRESBillingWeights=") wt=fv_all(ln)
    else if(substr(ln,1,7)=="State=") st=fv(ln)
    else if(substr(ln,1,14)=="PriorityTier=") prio=fvnum(ln)
  }
  if(nm==""||st=="") return
  tmem=0
  if(match(tres,/mem=[0-9]+M/)) tmem=substr(tres,RSTART+4,RLENGTH-5)+0
  tgpu=0
  if(match(tres,/gres\/gpu=[0-9]+/)){
    tt=substr(tres,RSTART+9); sub(/([^0-9]).*/,"",tt); tgpu=tt+0
  }
  wc=wm=wgg=0
  n=split(wt,parts,",")
  for(i=1;i<=n;i++){
    p=parts[i]
    k=index(p,"="); if(!k) continue
    key=substr(p,1,k-1); val=substr(p,k+1)
    gsub(/^ +/,"",key); gsub(/ +$/, "", key)
    gsub(/^ +/,"",val); gsub(/ +$/, "", val)
    if(length(val) && substr(val,length(val),1)=="G") val=substr(val,1,length(val)-1)
    if(key=="CPU") wc=val+0
    else if(key=="Mem") wm=val+0
    else if(key=="Gres/gpu") wgg=val+0
  }
  printf("%s\t%s\t%d\t%d\t%d\t%d\t%s\t%d\t%.17g\t%.17g\t%.17g\n", nm,maxt,tcpus,tnodes,tmem,tgpu,st,prio,wc,wm,wgg)
}
{ lines[++nr]=$0 }
END{
  blk=""
  for(i=1;i<=nr;i++){
    ln=lines[i]; sub(/^[[:space:]]+/, "", ln)
    if(i>1 && ln ~ /^PartitionName=/ && length(blk)>0){ emit(blk); blk="" }
    blk = blk lines[i] "\n"
  }
  if(length(blk)>0) emit(blk)
}
AWK

: >"$ENR"
while IFS=$'\t' read -r nm maxt tcpus tnodes tmem tgpu st prio wc wm wgg; do
  need_blob=0
  [[ "$SUMMARY" == "1" || "$GPU" != "0" || -n "${GPUTYPE}${GPUMEM}" ]] && need_blob=1
  ac="$tcpus"; am="$tmem"; ag="$tgpu"; blob=""
  nl=""
  if [[ "$st" == "UP" ]]; then
    nl="$(nodes_line_for_partition "$nm" || true)"
  fi
  if [[ "$st" == "UP" && -n "$nl" ]]; then
    if [[ "$HAVE_AVAIL" == "1" ]]; then
      IFS='|' read -r blob ac am ag < <(scontrol show node "$nl" | avail_and_blob_stream)
    elif [[ "$need_blob" == "1" ]]; then
      IFS='|' read -r blob _ac _am _ag < <(scontrol show node "$nl" | avail_and_blob_stream)
    fi
  fi
  printf '%s\t%s\t%d\t%d\t%d\t%d\t%s\t%d\t%.17g\t%.17g\t%.17g\t%d\t%d\t%d\t%s\n' \
    "$nm" "$maxt" "$tcpus" "$tnodes" "$tmem" "$tgpu" "$st" "$prio" "$wc" "$wm" "$wgg" \
    "${ac:-0}" "${am:-0}" "${ag:-0}" "$blob" >>"$ENR"
done < <(LC_ALL=C awk -f "$split_prog" "$RAW")

if [[ "$SUMMARY" == "1" ]]; then
  quiet "Fetching available resources..."
  quiet "Fetching GPU information..."
  tab=$'\t'
  LC_ALL=C awk -F'\t' -v OFS="$tab" -v show_avail="$HAVE_AVAIL" '
  BEGIN{
    printf("%-20s %-10s %-10s %-10s %-15s %-8s", "Partition", "CPU Wt", "Mem Wt", "GPU Wt", "Max Time", "State")
    if(show_avail) printf("%s", " AvailCPU AvailMemGB AvailGPU GPUInfo\n")
    else printf("%s", " GPUInfo\n")
    printf("%s\n", strrep("-", 95))
  }
  function strrep(c,n,o){ o=""; for(i=1;i<=n;i++) o=o c; return o }
  NF{ # line
    nm=$1; maxt=$2; st=$7; prio=$8; wc=$9; wm=$10; wgg=$11; ac=$12; am=$13; ag=$14; gb=$15
    if(show_avail){
      printf("%-20s %-10g %-10g %-10g %-15s %-8s %8d %10.1f %8d %s\n", nm,wc+0,wm+0,wgg+0,maxt,st,ac,am/1024,ag,gb)
    } else {
      printf("%-20s %-10g %-10g %-10g %-15s %-8s %s\n", nm,wc+0,wm+0,wgg+0,maxt,st,gb)
    }
  }' "$ENR"
  exit 0
fi

req_cpu="$CPU"
req_mem_mb="$(LC_ALL=C awk -v gb="$MEM" 'BEGIN{printf "%d", (gb+0)*1024}')"
req_gpu="$GPU"
req_h="${TIME:-}"
need_time=0; [[ -n "${TIME:-}" ]] && need_time=1

: >"$CANDS"
while IFS=$'\t' read -r nm maxt tcpus tnodes tmem tgpu st prio wc wm wgg ac am ag blob; do
  [[ "$st" == "UP" ]] || continue
  if [[ "$req_gpu" -gt 0 && "$nm" == "serial_requeue" ]]; then continue; fi
  if [[ "$req_gpu" == "0" && "$nm" == "gpu_requeue" ]]; then continue; fi
  if [[ "$req_gpu" == "0" && "$nm" == "gpu_test" ]]; then continue; fi

  if [[ -n "$GPUTYPE" ]]; then
    bt="$(lc "$blob")"; gt="$(lc "$GPUTYPE")"; [[ "$bt" == *"${gt}"* ]] || continue
  fi
  if [[ -n "$GPUMEM" ]]; then
    bt="$(lc "$blob")"; gm="$(lc "$GPUMEM")"; [[ "$bt" == *"${gm}"* ]] || continue
  fi

  chk_c="$ac"
  chk_m="$am"
  chk_g="$ag"
  if [[ "$HAVE_AVAIL" == "0" ]]; then
    chk_c="$tcpus"
    chk_m="$tmem"
    chk_g="$tgpu"
  fi

  if [[ "$req_cpu" -gt "$chk_c" && "$chk_c" -gt 0 ]]; then continue; fi
  if [[ "$req_mem_mb" -gt "$chk_m" && "$chk_m" -gt 0 ]]; then continue; fi
  if [[ "$req_gpu" -gt 0 && "$chk_g" == "0" ]]; then continue; fi
  if [[ "$req_gpu" -gt "$chk_g" && "$chk_g" -gt 0 ]]; then continue; fi

  if [[ "$need_time" == "1" ]]; then
    pm="$(partition_minutes "$maxt")"
    min_needed=$(( req_h * 60 ))
    if [[ "$pm" -lt 999999000 && "$pm" -lt "$min_needed" ]]; then continue; fi
  fi

  cost="$(LC_ALL=C awk -v c="$req_cpu" -v m="$MEM" -v g="$req_gpu" -v wc="$wc" -v wm="$wm" -v wgg="$wgg" \
    'BEGIN{printf "%.12f", (c+0)*wc + (m+0)*wm + (g+0)*wgg}')"
  printf '%s\t%d\t%s\t%s\t%.17g\t%.17g\t%.17g\t%d\t%d\t%d\t%s\t%d\t%d\t%d\n' \
    "$cost" "$prio" "$nm" "$maxt" "$wc" "$wm" "$wgg" "$ac" "$am" "$ag" "$blob" "$tcpus" "$tmem" "$tgpu" >>"$CANDS"
done <"$ENR"

if [[ ! -s "$CANDS" ]]; then
  [[ "$NAMEONLY" == "1" ]] || quiet "No suitable partitions found for your requirements."
  exit 1
fi

SORTED="$(mktemp)"
trap 'rm -f "$RAW" "$ENR" "$CANDS" "$split_prog" "$SORTED"' EXIT
LC_ALL=C sort -s -t $'\t' -k1,1n -k2,2n "$CANDS" >"$SORTED"

if [[ "$NAMEONLY" == "1" ]]; then
  awk -F '\t' 'NR==1{print $3}' "$SORTED"
  exit 0
fi

json_escape() {
  LC_ALL=C awk -v s="$1" 'BEGIN{
    gsub(/\\/, "\\\\", s)
    gsub(/\r|\\n|\\t/, " ", s)
    gsub(/"/, "\\\"", s)
    printf "%s", s
  }'
}

if [[ "$JSON_OUT" == "1" ]]; then
  printf '[\n'
  first_json=1
  while IFS=$'\t' read -r cost prio nm maxt wc wm wgg ac am ag blob tcpus tmem tgpu; do
    [[ "$first_json" == "1" ]] || printf ',\n'
    first_json=0
    nmj="$(json_escape "$nm")"
    mj="$(json_escape "$maxt")"
    bj="$(json_escape "$blob")"
    tmem_gb=$(( (tmem + 512) / 1024 ))
    avail_json=""
    if [[ "$HAVE_AVAIL" == "1" ]]; then
      avail_json=$(printf ',
      "available_cpus": %s,
      "available_memory_gb": %s,
      "available_gpus": %s' "$ac" "$(( (am + 512) / 1024 ))" "$ag")
    fi
    # shellcheck disable=SC2086
    printf \
      '  {\n    "name": "%s",\n    "cost": %s,\n    "max_time": "%s",\n    "priority_tier": %s,\n    "billing_weights": {"CPU": %s, "Mem": %s, "Gres/gpu": %s},\n    "total_cpus": %s,\n    "total_memory_gb": %s,\n    "total_gpus": %s%s,\n    "gpu_blob": "%s"\n  }' \
      "$nmj" "$cost" "$mj" "$prio" "$wc" "$wm" "$wgg" "$tcpus" "$tmem_gb" "$tgpu" "$avail_json" "$bj"
  done <"$SORTED"
  printf '\n]\n'
  exit 0
fi

rtag="available"
[[ "$HAVE_AVAIL" == "0" ]] && rtag="total"

quiet ""
quiet "Recommended partitions for your requirements (using ${rtag} resources):"
quiet "  CPUs: ${req_cpu}"
quiet "  Memory: ${MEM} GB"
quiet "  GPUs: ${req_gpu}"
[[ -n "${GPUTYPE:-}" ]] && quiet "  GPU type: ${GPUTYPE}"
[[ -n "${GPUMEM:-}" ]] && quiet "  GPU memory: ${GPUMEM}"
[[ -n "${TIME:-}" ]] && quiet "  Max time: ${TIME} hours"
quiet ""

tab=$'\t'
if [[ "$HAVE_AVAIL" == "1" ]]; then
  printf "%s\n" "Rank${tab}Partition${tab}Cost${tab}Max Time${tab}Priority${tab}Available resources"
else
  printf "%s\n" "Rank${tab}Partition${tab}Cost${tab}Max Time${tab}Priority${tab}Total resources"
fi
printf "%s\n" "--------------------------------------------------------------------------------"

rank=0
while IFS=$'\t' read -r cost prio nm maxt wc wm wgg ac am ag blob tcpus tmem tgpu; do
  rank=$((rank+1))
  [[ "$rank" -le 10 ]] || break
  det=""
  if [[ "$HAVE_AVAIL" == "1" ]]; then
    if [[ "$ac" -gt 0 ]]; then det="${det}${det:+, }${ac} CPUs"; fi
    if [[ "$am" -gt 0 ]]; then det="${det}${det:+, }$(( am/1024 )) GB"; fi
    if [[ "$ag" -gt 0 ]]; then det="${det}${det:+, }${ag} GPUs"; fi
    if [[ -n "$blob" ]]; then det="${det}${det:+, }(${blob})"; fi
  else
    if [[ "$tcpus" -gt 0 ]]; then det="${det}${det:+, }${tcpus} CPUs"; fi
    if [[ "$tmem" -gt 0 ]]; then det="${det}${det:+, }$(( (tmem+512)/1024 )) GB"; fi
    if [[ "$tgpu" -gt 0 ]]; then det="${det}${det:+, }${tgpu} GPUs"; fi
    if [[ -n "$blob" ]]; then det="${det}${det:+, }(${blob})"; fi
  fi
  printf "%d\t%s\t%s\t%s\t%s\t%s\n" "$rank" "$nm" "$cost" "$maxt" "$prio" "$det"
done <"$SORTED"

IFS=$'\t' read -r best_cost best_prio best_nm best_maxt best_wc best_wm best_wgg best_ac best_am best_ag best_blob best_tcpus best_tmem best_tgpu < <(head -n1 "$SORTED")

quiet ""
quiet "Best recommendation: ${best_nm}"
quiet "   Cost: ${best_cost} billing units"
quiet "   Max time: ${best_maxt}"
quiet "   Priority tier: ${best_prio}"

cmd="sbatch --partition=${best_nm} --cpus-per-task=${req_cpu} --mem=${MEM}G"
[[ "$req_gpu" != "0" ]] && cmd="${cmd} --gres=gpu:${req_gpu}"
[[ -n "${TIME:-}" ]] && cmd="${cmd} --time=${req_h}:00:00"
cmd="${cmd} your_script.sh"
quiet ""
quiet "Suggested sbatch command:"
quiet "   ${cmd}"
