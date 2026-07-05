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

# Fake ssh: a banner/MOTD line (must be skipped), one process (2.5% of a
# 16000000 kB machine), and the MemTotal block — all in a single call, exercising
# the combined ps + MemTotal round-trip. ST_TEST_NO_MEMTOTAL drops the MemTotal
# line to simulate a node where the probe fails (restricted /proc, non-Linux).
cat >"${TMP}/bin/ssh" <<'EOF'
#!/usr/bin/env bash
echo "*** Welcome to the cluster - unauthorized access prohibited ***"
echo "1234 10.0 2.5 python train.py"
echo "===ST_MEM_SPLIT==="
if [[ "${ST_TEST_NO_MEMTOTAL:-0}" == "0" ]]; then
  echo "MemTotal:       16000000 kB"
fi
EOF
chmod +x "${TMP}/bin/ssh"

json="$(PATH="${TMP}/bin:${PATH}" python3 "${ROOT}/libexec/monitor.py" 123 --json 2>/dev/null)"

PATH="${TMP}/bin:${PATH}" python3 - <<PY
import json
data = json.loads('''${json}''')
assert [d["node"] for d in data] == ["cnode1", "cnode2"], data
for d in data:
    assert d["error"] is None, d
    # The banner line is skipped; only the real ps row is counted.
    assert d["process_count"] == 1, d
    # 2.5% of 16000000 kB (= 15625 MB) -> ~390.6 MB, not the raw 2.5.
    mb = d["processes"][0]["memory_mb"]
    assert abs(mb - 390.625) < 0.1, mb
    assert abs(d["memory_mb"] - 390.625) < 0.1, d
print("ok")
PY

# When MemTotal cannot be read, the node still returns process data (no error);
# memory stays as the raw %mem rather than the run failing.
json_nomem="$(ST_TEST_NO_MEMTOTAL=1 PATH="${TMP}/bin:${PATH}" python3 "${ROOT}/libexec/monitor.py" 123 --json 2>/dev/null)"
PATH="${TMP}/bin:${PATH}" python3 - <<PY
import json
data = json.loads('''${json_nomem}''')
for d in data:
    assert d["error"] is None, d
    assert d["process_count"] == 1, d
    assert abs(d["processes"][0]["memory_mb"] - 2.5) < 0.01, d
print("ok")
PY

printf 'monitor tests passed\n'
