#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "${TMP}/bin"

# Fake scontrol: resolves the job's node list and expands the hostlist.
cat >"${TMP}/bin/scontrol" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-} ${2:-}" == "show job" ]]; then
  cat <<'J'
JobId=123 JobName=test
   JobState=RUNNING Reason=None
   NodeList=cnode[1-2]
J
elif [[ "${1:-} ${2:-}" == "show hostnames" ]]; then
  printf 'cnode1\ncnode2\n'
else
  exit 1
fi
EOF
chmod +x "${TMP}/bin/scontrol"

cat >"${TMP}/bin/whoami" <<'EOF'
#!/usr/bin/env bash
printf 'tester\n'
EOF
chmod +x "${TMP}/bin/whoami"

# Fake ssh: one process (2.5% of a 16000000 kB machine) plus the MemTotal block,
# returned in a single call — exercises the combined ps + MemTotal round-trip.
cat >"${TMP}/bin/ssh" <<'EOF'
#!/usr/bin/env bash
cat <<'OUT'
1234 10.0 2.5 python train.py
===ST_MEM_SPLIT===
MemTotal:       16000000 kB
OUT
EOF
chmod +x "${TMP}/bin/ssh"

json="$(PATH="${TMP}/bin:${PATH}" python3 "${ROOT}/libexec/monitor.py" 123 --json 2>/dev/null)"

PATH="${TMP}/bin:${PATH}" python3 - <<PY
import json
data = json.loads('''${json}''')
assert [d["node"] for d in data] == ["cnode1", "cnode2"], data
for d in data:
    assert d["error"] is None, d
    assert d["process_count"] == 1, d
    # 2.5% of 16000000 kB (= 15625 MB) -> ~390.6 MB, not the raw 2.5.
    mb = d["processes"][0]["memory_mb"]
    assert abs(mb - 390.625) < 0.1, mb
    assert abs(d["memory_mb"] - 390.625) < 0.1, d
print("ok")
PY

printf 'monitor tests passed\n'
