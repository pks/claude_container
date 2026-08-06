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
3. **12h enforcement + snapshot** — wall-clock killer + freeze workspace at cap.
4. **Scorer sidecar** — holds test data; canary-inject → run submitted `decode.sh` in
   a no-net copy of the same image → strip canaries → sacreBLEU once. Bench core.
5. **Canary generator** — per-run synthetic EN source lines.
6. **from-scratch inspection** — assert non-pretrained init / artifact provenance.

## Strip (mithril spot machinery — irrelevant for on-demand bench)

`ops/mithril-watch.sh`, `ops/mithril-hook.sh`, `ops/mithril-nudge.txt`,
`ops/mithril-host/*`, `pi-extensions/mithril/`, and their wiring in Dockerfile/run.sh.
Bench runs on-demand (no preemption) by design.

## Build order

1. Strip mithril + data-bake layer + offline env (self-contained, low-risk).
2. Egress lock (needs the mechanism decision).
3. Scorer sidecar + canary gen (the bench core; independent of the agent image).
4. 12h enforcement + from-scratch inspection.
5. Wire TASKCARD/HOST-bench into seed; end-to-end smoke on one throwaway run.

## Invariants

- Agent container: no test data, no egress except inference, offline tooling.
- Scorer: separate, holds test data, runs decode with NO network, scores once.
- Deliverable: `model/` (≤10 GB) + `decode.sh <src> <hyps>`; harness runs it.
