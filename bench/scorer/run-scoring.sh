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
echo "run-scoring: scoring $SUBMISSION (SEED=$SEED) ..." >&2
SEED="$SEED" TESTDIR="$TESTDIR" IMAGE="$IMAGE" "$SCRIPTDIR/score.sh" "$SUBMISSION"
