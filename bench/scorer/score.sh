#!/bin/bash
# Bench scorer — runs a submitted system on the WITHHELD test in a locked-down,
# no-network container and scores it once. See bench/scorer/README.md.
#
#   ./score.sh <submission_dir> [workdir]
#
# submission_dir is the agent's SELF-CONTAINED deliverable: `decode.sh` +
# `model/` + any code decode.sh needs. ONLY this dir is mounted and it is what
# the 10 GB cap measures — so weights cannot hide outside it (audit HIGH). Env:
#   IMAGE          bench image (torch + the baked deps) [mtbench-container]
#   TESTDIR        test.src/test.ref (+ optional dev.src for canaries) [./testdata]
#   SEED           per-run seed for canaries + shuffle [0]
#   K              number of canary lines [100]
#   DECODE_BUDGET  seconds allowed for decode.sh [3600]
set -euo pipefail

SUBMISSION="${1:?usage: score.sh <submission_dir> [workdir]}"
WORK="${2:-$(mktemp -d)}"
IMAGE="${IMAGE:-mtbench-container}"
SCRIPTDIR="$(cd "$(dirname "$0")" && pwd)"
TESTDIR="${TESTDIR:-$SCRIPTDIR/testdata}"
SEED="${SEED:-0}"; K="${K:-100}"; DECODE_BUDGET="${DECODE_BUDGET:-3600}"
CAP=$((10 * 1024 * 1024 * 1024))   # 10 GB cap on the WHOLE submission dir

# 1. pre-checks (fail = void, exit 2). Cap the ENTIRE submission dir, and later
#    mount ONLY it — so nothing outside (ckpt/, .venv, logs) is reachable and the
#    cap can't be dodged by stashing weights elsewhere.
[ -d "$SUBMISSION" ]              || { echo "void: submission dir $SUBMISSION missing" >&2; exit 2; }
[ -x "$SUBMISSION/decode.sh" ]    || { echo "void: no executable decode.sh in submission" >&2; exit 2; }
[ -d "$SUBMISSION/model" ]        || { echo "void: no model/ in submission" >&2; exit 2; }
bytes=$(du -sb "$SUBMISSION" | cut -f1)
[ "$bytes" -le "$CAP" ] || { echo "void: submission ${bytes}B exceeds 10GB cap" >&2; exit 2; }
[ -f "$TESTDIR/test.src" ] && [ -f "$TESTDIR/test.ref" ] || { echo "no test data in $TESTDIR (run prepare_test.py)" >&2; exit 1; }

# preflight: only submission/ is mounted (at /art), so scripts must be self-contained.
# Warn (advisory) if any .sh/.py references a path outside it — an absolute
# /workspace or /home path, or a ../ escape won't exist at decode time and voids
# the run. grep -r --include avoids glob/missing-file errors under `set -o pipefail`.
PREFLIGHT_RE='/workspace|/home/[a-z]|\.\./'
if grep -rInE --include='*.sh' --include='*.py' "$PREFLIGHT_RE" "$SUBMISSION" 2>/dev/null | grep -q .; then
  echo "WARN: submission scripts reference paths outside submission/ — decode may void:" >&2
  grep -rInE --include='*.sh' --include='*.py' "$PREFLIGHT_RE" "$SUBMISSION" 2>/dev/null | head -6 | sed 's/^/  /' >&2
fi

# advisory from-scratch provenance scan (airgap is the real enforcement)
python3 "$SCRIPTDIR/check_from_scratch.py" "$SUBMISSION" | tee "$WORK/from_scratch.json" >&2

# 2-3. canaries + shuffled decode input (+ recorded permutation). Draw canaries
#      from real dev source when available so they're stylistically identical to
#      the test source (a word-salad fallback is used otherwise).
POOL=""; [ -f "$TESTDIR/dev.src" ] && POOL="$TESTDIR/dev.src"
python3 "$SCRIPTDIR/make_canaries.py" "$K" "$SEED" "$WORK/canaries.txt" "$POOL"
python3 "$SCRIPTDIR/build_input.py" "$TESTDIR/test.src" "$WORK/canaries.txt" \
        "$WORK/decode_input.txt" "$WORK/perm.json" "$SEED"

# 4. Run the submission: NO network, GPU on, ONLY the submission dir mounted (ro),
#    dropped privileges (non-root, no new privs, all caps dropped, pid-limited),
#    writable scratch on tmpfs, time-bounded. timeout/exit!=0/wrong-count = void.
echo "scorer: running decode.sh (locked, no network, budget ${DECODE_BUDGET}s)..." >&2
t0=$(date +%s)
docker run --rm --network none --gpus all \
  --user "$(id -u):$(id -g)" --cap-drop ALL --security-opt no-new-privileges --pids-limit 1024 \
  --tmpfs /tmp:exec,size=8g -e HOME=/tmp -e TORCH_EXTENSIONS_DIR=/tmp/torchext \
  -v "$SUBMISSION":/art:ro -v "$WORK":/work \
  -w /art "$IMAGE" \
  bash -lc "timeout ${DECODE_BUDGET} ./decode.sh /work/decode_input.txt /work/out.hyp"
decode_s=$(( $(date +%s) - t0 ))

# 5. un-permute, strip canaries, sacreBLEU once
python3 "$SCRIPTDIR/score.py" "$WORK/out.hyp" "$WORK/perm.json" "$TESTDIR/test.ref" "$WORK/result.json"
python3 - "$WORK/result.json" "$decode_s" "$bytes" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
r["decode_seconds"] = int(sys.argv[2]); r["submission_bytes"] = int(sys.argv[3])
json.dump(r, open(sys.argv[1], "w"), indent=2)
print("\nscorer: FINAL", json.dumps(r))
PY
echo "scorer: result -> $WORK/result.json" >&2
