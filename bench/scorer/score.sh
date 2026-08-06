#!/bin/bash
# Bench scorer — runs a submitted artifact on the WITHHELD test in a no-network
# container and scores it once. See bench/scorer/README.md.
#
#   ./score.sh <artifact_dir> [workdir]
#
# artifact_dir must contain `model/` and an executable `decode.sh`. Env:
#   IMAGE          bench image (has torch + the deps decode.sh needs) [mtbench-container]
#   TESTDIR        holds test.src + test.ref (host-only; from prepare_test.py) [./testdata]
#   SEED           per-run seed for canaries + shuffle [0]
#   K              number of canary lines [100]
#   DECODE_BUDGET  seconds allowed for decode.sh [3600]
set -euo pipefail

ARTIFACT="${1:?usage: score.sh <artifact_dir> [workdir]}"
WORK="${2:-$(mktemp -d)}"
IMAGE="${IMAGE:-mtbench-container}"
SCRIPTDIR="$(cd "$(dirname "$0")" && pwd)"
TESTDIR="${TESTDIR:-$SCRIPTDIR/testdata}"
SEED="${SEED:-0}"; K="${K:-100}"; DECODE_BUDGET="${DECODE_BUDGET:-3600}"
CAP=$((10 * 1024 * 1024 * 1024))   # 10 GB artifact cap

# 1. pre-checks (fail = void, exit 2)
[ -x "$ARTIFACT/decode.sh" ] || { echo "void: no executable decode.sh in $ARTIFACT" >&2; exit 2; }
[ -d "$ARTIFACT/model" ]     || { echo "void: no model/ in $ARTIFACT" >&2; exit 2; }
bytes=$(du -sb "$ARTIFACT/model" | cut -f1)
[ "$bytes" -le "$CAP" ] || { echo "void: model/ ${bytes}B exceeds 10GB cap" >&2; exit 2; }
[ -f "$TESTDIR/test.src" ] && [ -f "$TESTDIR/test.ref" ] || { echo "no test data in $TESTDIR (run prepare_test.py)" >&2; exit 1; }

# 2-3. canaries + shuffled decode input (+ recorded permutation)
python3 "$SCRIPTDIR/make_canaries.py" "$K" "$SEED" "$WORK/canaries.txt"
python3 "$SCRIPTDIR/build_input.py" "$TESTDIR/test.src" "$WORK/canaries.txt" \
        "$WORK/decode_input.txt" "$WORK/perm.json" "$SEED"

# 4. run the artifact: NO network at all (self-contained decode), GPU on, in the
#    bench image, cwd = the artifact dir, time-bounded. timeout/exit!=0 = void.
echo "scorer: running decode.sh (no network, budget ${DECODE_BUDGET}s)..." >&2
t0=$(date +%s)
docker run --rm --network none --gpus all \
  -v "$ARTIFACT":/art:ro -v "$WORK":/work \
  -w /art "$IMAGE" \
  bash -lc "timeout ${DECODE_BUDGET} ./decode.sh /work/decode_input.txt /work/out.hyp"
decode_s=$(( $(date +%s) - t0 ))

# 5. un-permute, strip canaries, sacreBLEU once
python3 "$SCRIPTDIR/score.py" "$WORK/out.hyp" "$WORK/perm.json" "$TESTDIR/test.ref" "$WORK/result.json"
python3 - "$WORK/result.json" "$decode_s" "$bytes" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
r["decode_seconds"] = int(sys.argv[2]); r["artifact_bytes"] = int(sys.argv[3])
json.dump(r, open(sys.argv[1], "w"), indent=2)
print("\nscorer: FINAL", json.dumps(r))
PY
echo "scorer: result -> $WORK/result.json" >&2
