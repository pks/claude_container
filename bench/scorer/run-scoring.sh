#!/bin/bash
# One-shot scoring wrapper: fetch the withheld test once (online, host-side via
# the bench image), then run the locked scorer on a submission. Idempotent —
# skips the fetch if testdata/ already has test.src + test.ref.
#
#   ./run-scoring.sh [submission_dir]
#
# submission_dir defaults to the on-node bench deliverable. Env passthrough to
# score.sh: IMAGE, SEED, K, DECODE_BUDGET, TESTDIR.
set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${IMAGE:-mtbench-container}"
SEED="${SEED:-0}"
TESTDIR="${TESTDIR:-$SCRIPTDIR/testdata}"
SUBMISSION="${1:-$HOME/exp/claude_container/state/workspace/submission}"

[ -d "$SUBMISSION" ] || { echo "no submission dir: $SUBMISSION" >&2; exit 1; }

# 1. Fetch newstest2014 (test.src/.ref) + dev.src canary pool — ONLINE, once.
#    The image is baked HF_*_OFFLINE=1; override just for this fetch. Runs as the
#    caller so testdata/ stays host-owned. Skipped if already present.
if [ -f "$TESTDIR/test.src" ] && [ -f "$TESTDIR/test.ref" ]; then
  echo "run-scoring: testdata present ($TESTDIR) — skipping fetch" >&2
else
  echo "run-scoring: fetching withheld test into $TESTDIR ..." >&2
  mkdir -p "$TESTDIR"
  docker run --rm --network host \
    -e HF_DATASETS_OFFLINE=0 -e HF_HUB_OFFLINE=0 -e TRANSFORMERS_OFFLINE=0 \
    -e HF_HOME=/tmp/hfscore \
    -u "$(id -u):$(id -g)" \
    -v "$SCRIPTDIR":/s -w /s "$IMAGE" \
    python3 prepare_test.py testdata/
fi

# 2. Score (locked container: --network none, GPU on, only submission/ mounted).
#    Pin the workdir so we can read result.json back and fold in cost below.
echo "run-scoring: scoring $SUBMISSION (SEED=$SEED) ..." >&2
WORK="$(mktemp -d)"
SEED="$SEED" TESTDIR="$TESTDIR" IMAGE="$IMAGE" "$SCRIPTDIR/score.sh" "$SUBMISSION" "$WORK"
RESULT="$WORK/result.json"

# 3. Fold in the run's token usage + cost. The pi session jsonl lives on the
#    state volume beside the submission ($STATE_DIR/home/.pi/agent/sessions,
#    where submission = $STATE_DIR/workspace/submission) — score.sh stays
#    submission-isolated; this is the wrapper's job. Best-effort: a missing
#    session dir just leaves the BLEU-only result intact.
REPO_ROOT="$(cd "$SCRIPTDIR/../.." && pwd)"
STATE_DIR="$(cd "$SUBMISSION/../.." 2>/dev/null && pwd || true)"
SESSIONS="$STATE_DIR/home/.pi/agent/sessions"
if [ -f "$RESULT" ] && [ -d "$SESSIONS" ] && python3 "$REPO_ROOT/ops/bench-cost.py" "$SESSIONS" > "$WORK/cost.json" 2>/dev/null; then
  python3 - "$RESULT" "$WORK/cost.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
c = json.load(open(sys.argv[2]))
r["agent_model"] = c.get("model")
r["agent_requests"] = c.get("requests")
r["agent_tokens"] = c.get("tokens")
r["inference_cost_usd"] = c.get("cost_usd")
json.dump(r, open(sys.argv[1], "w"), indent=2)
print("run-scoring: FINAL", json.dumps({
    "test_bleu": r.get("test_bleu"),
    "inference_cost_usd": r.get("inference_cost_usd"),
    "agent_model": r.get("agent_model"),
    "decode_seconds": r.get("decode_seconds"),
    "submission_bytes": r.get("submission_bytes"),
}))
PY
else
  echo "run-scoring: no session usage found ($SESSIONS) — BLEU-only result" >&2
fi
echo "run-scoring: full result -> $RESULT" >&2
