# MT-Modeling-Bench harness — build plan (branch: bench)

Bench harness, forked from claude_container on the `bench` branch. `main` stays the
live-experiment harness; all bench work lands here. Agent-facing task spec + scoring
design live in the meta repo (`bench/TASKCARD.md`, `bench/SCORING.md`); this file is
the implementation roadmap and the component→origin map.

## Reuse map (claude_container → bench)

| piece | origin | change |
|---|---|---|
| base image (CUDA13/torch/uv/pi/claude/extensions) | Dockerfile | +data-bake, +offline env, −HF_TOKEN, +MT deps |
| GPU device nodes + cgroup-reload fix | run.sh | keep verbatim |
| image/seed/run | Makefile | keep; seed TASKCARD+HOST-bench |
| state-dir bind-mount (workspace/home) | run.sh | keep |
| azure-openai/anthropic extensions (+compaction fix) | pi-extensions/ | keep |
| entrypoint / settings / .config | ops/, pi-settings/ | keep |
| plan/PLAN.md+HOST.md → doc/ seed | Makefile | keep; content swap |

## New / changed (the bench-specific work)

1. **Egress lock** — DONE. Allowlist proxy, fail-closed: agent runs on an
   `--internal` docker network (no route out) whose only peer is a tinyproxy sidecar
   (same image, proxy entrypoint) that default-denies every destination except the
   inference host(s). `ops/bench-egress.sh` orchestrates net+proxy then hands to
   run.sh; run.sh honors `DOCKER_NETWORK` + forwards proxy env. Even if a client
   ignores the proxy env, the internal net has no egress → fails closed, no leak.
2. **Offline data bake** — Dockerfile layer: WMT14 train+dev(refs) cached in image,
   `HF_DATASETS_OFFLINE=1`/`TRANSFORMERS_OFFLINE=1`, drop `HF_TOKEN`. **Test data NOT
   in image.**
3. **12h enforcement** — DONE. `ops/bench-egress.sh` wraps the agent in
   `timeout --signal=SIGINT --kill-after=GRACE $BENCH_WALL` (default 12h) + a teardown
   trap. No explicit snapshot: /workspace is bind-mounted to `$STATE_DIR/workspace`,
   so the deliverable at stop time is already durable on the host.
4. **Scorer sidecar** — DONE (`bench/scorer/`). Holds test data; canary-inject →
   run `decode.sh` in a `--network none` image copy → strip → sacreBLEU once. Pure-
   python plumbing validated (perfect→100, garbage→0, void on line-count mismatch).
5. **Canary generator** — DONE (`bench/scorer/make_canaries.py`, folded into scorer).
6. **from-scratch inspection** — DONE (advisory). `bench/scorer/check_from_scratch.py`
   scans the artifact for foreign-provenance markers (wired into score.sh, advisory).
   Real enforcement is the airgap: no pretrained weights in the image, none fetchable.
7. **Preemptible-host support** — DONE. The bench MUST run on preemptible/spot GPUs,
   so (a) the 12h is **compute-time, not wall-time**: `ops/bench-egress.sh` persists
   active seconds to `$STATE_DIR/.bench_elapsed_s` via a heartbeat, caps at
   `BENCH_BUDGET_S`, and preemption gaps don't count (verified: 4s active → gap →
   resume → cap at budget); (b) a **generic auto-resume** (`ops/host-resume/`,
   de-branded + hardened from the pilot's mithril unit) relaunches through
   bench-egress after a reboot, so the egress lock + clock reapply. `.bench_done`
   stops relaunch once the budget is spent or the agent finishes.

## Stripped vs kept (mithril → generic)

Removed the **mithril-SPECIFIC** machinery (`ops/mithril-*.sh`, `mithril-nudge.txt`,
`pi-extensions/mithril/`, the `/opt/mithril` signal wiring) — a proprietary spot
protocol. But preemption itself is NOT stripped: the hardened resume unit was
**restored generically** as `ops/host-resume/` (#7 above), because the bench targets
preemptible hosts. On-demand still works (no resume unit installed = single segment).

## Build order

1. Strip mithril + data-bake layer + offline env (self-contained, low-risk).
2. Egress lock (needs the mechanism decision).
3. Scorer sidecar + canary gen (the bench core; independent of the agent image).
4. 12h enforcement + from-scratch inspection.
5. Wire TASKCARD/HOST-bench into seed — DONE. `make bench-stage` copies
   `bench/TASKCARD.md`→`plan/PLAN.md` + `bench/HOST-bench.md`→`plan/HOST.md`; `make seed`
   ships them to `doc/`. `make bench` = egress+clock launcher. IMAGE renamed
   `claude-container`→`mtbench-container` (Makefile+run.sh). TASKCARD/SCORING/README/
   HOST-bench now live in-branch (self-contained). End-to-end smoke still needs a
   docker+GPU host (see README "Runtime-verify TODO").

## Status: v0 complete (modulo GPU-host verification)

All 7 pieces built + committed on `bench`. Verified in isolation (scorer plumbing,
canaries, compute-clock fairness, shells). Not yet run on a real docker+GPU host —
those are the 4 runtime-verify TODOs in bench/README.md.

## Invariants

- Agent container: no test data, no egress except inference, offline tooling.
- Scorer: separate, holds test data, runs decode with NO network, scores once.
- Deliverable: `model/` (≤10 GB) + `decode.sh <src> <hyps>`; harness runs it.
