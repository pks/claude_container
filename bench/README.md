# MachineTranslationModelingBench

Agentic ML benchmark: drop a frontier coding agent on one GPU with raw WMT14 EN→DE
and 12 h of compute; measure the MT model it trains from scratch. Forked from the
claude_container harness (branch `bench`). Agent sees `TASKCARD.md`; operator reads
this + `scorer/README.md`.

## Quick start

```
# build + run (needs .env with AZURE_BASE_URL + one API key)
make image                                    # build mtbench-container (bakes WMT14 train+dev)
make bench-stage                              # TASKCARD.md -> plan/PLAN.md
make seed                                     # populate $STATE_DIR from the image
make bench PROFILE=pi-azure GPU=all           # egress lock + 12h compute clock + agent

# preemptible hosts: auto-resume on reboot (after editing /etc/mtbench-resume.env)
sudo bash ops/host-resume/install.sh --start

# score the submission
cd bench/scorer
python3 prepare_test.py testdata/             # once, online — test held here, never in the image
IMAGE=mtbench-container SEED=1 DECODE_BUDGET=3600 ./score.sh <state>/workspace/submission
```

## Files

| path | role |
|---|---|
| `TASKCARD.md` | agent-facing spec — seeded to `doc/PLAN.md` |
| `scorer/` | external scorer (holds test, canaries, runs `decode.sh`, sacreBLEU once) — see `scorer/README.md` |
| `../ops/bench-egress.sh` | launcher: egress lock + compute-time budget |
| `../ops/host-resume/` | generic preempt-resume unit |

The **task card is not baked into the image** — `bench-stage`+`seed` drop it into
`$STATE_DIR/workspace/doc/PLAN.md` (which the `/workspace` bind-mount would shadow
anyway; it lives in durable state that survives preemption). Change the task = edit
`TASKCARD.md`, `make bench-stage && make reseed` — no image rebuild.

## Integrity model

- **Airgap except inference** (egress lock, fail-closed) → from-scratch, no external
  data, no ref lookup, by construction.
- **Test never in the agent's world** — image has train+dev only; the scorer holds test.
- **Deliverable = `submission/`** (weights + `decode.sh`); the harness runs it on the
  withheld test, `--network none`, mounting **only** `submission/` (10 GB cap on the
  whole dir) → no self-translate / peek / phone-home / cap-dodge.
- **Canaries** sampled from real dev (indistinguishable from test) hide which lines
  count + tripwire special-casing; advisory provenance scan; **agent runs unprivileged**.
- **Compute-time budget** (not wall) → preemption doesn't confound the score.

## Design (fork of claude_container)

- **Reused:** base image (CUDA/torch/uv/pi), GPU handling, state bind-mount, seed/run,
  azure-openai/anthropic extensions.
- **New:** offline data-bake (test withheld), egress lock (allowlist proxy), scorer +
  canaries, compute-time clock, generic auto-resume.
- **Stripped:** mithril-specific spot machinery; Claude Code CLI + caveman (pi-only for
  reproducibility); agent sudo.

## Runtime verification (docker + GPU host, 2026-08-06)

1. ✅ Data resolves (datasets 4.8.5, no `trust_remote_code`); test excluded. Fixed a
   real assertion bug — HF names the test file `wmt14-test.arrow`, not `newstest2014`.
2. ✅ Egress fail-closed — `--internal` net gets no internet and no DNS.
3. ✅ Scorer end-to-end through docker; **isolation confirmed** (decode can't read
   outside `submission/`); void on wrong line count.
4. ✅ Compute-clock fairness (active-only, gap-free) + resume guards.

Residual (need a full run / built image, not blockers): real-model GPU decode,
tinyproxy allowlist forwarding on the built image.
