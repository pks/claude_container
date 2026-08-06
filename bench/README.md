# MachineTranslationModelingBench

An agentic ML benchmark: drop a frontier coding agent on one GPU with raw WMT14
EN→DE and 12 h of compute, and measure the translation model it trains from
scratch. Forked from the claude_container harness (branch `bench`).

## What's here

| file | role |
|---|---|
| `TASKCARD.md` | agent-facing spec (goal, rules, deliverable, scoring) — seeded to `doc/PLAN.md` |
| `HOST-bench.md` | host facts — seeded to `doc/HOST.md` |
| `SCORING.md` | operator-facing harness + scoring design |
| `HARNESS.md` | build roadmap + component→origin map |
| `scorer/` | external scorer: test held here, canaries, run `decode.sh`, sacreBLEU once |
| `../ops/bench-egress.sh` | launcher: egress lock + compute-time budget |
| `../ops/host-resume/` | generic preempt-resume unit (compute-clock aware) |

## Integrity model

- **Airgap except inference** (`bench-egress.sh` egress lock, fail-closed) → from-
  scratch + no-external-data + no-ref-lookup by construction.
- **Test never in the agent's world** — baked image has train+dev only; the scorer
  holds test.
- **Deliverable = weights + `decode.sh`**, the harness runs it on the withheld test
  with `--network none` → no self-translate / peek / phone-home.
- **Canaries** hide which lines count + tripwire special-casing; **10 GB cap** +
  advisory provenance scan bound smuggled models.
- **Compute-time budget** (not wall) → preemption doesn't confound the score.

## Run it

```
make image                                  # build mtbench-container (online: bakes WMT14 train+dev)
make bench-stage                            # TASKCARD.md->plan/PLAN.md, HOST-bench.md->plan/HOST.md
make seed                                   # populate $STATE_DIR from the image
make bench PROFILE=pi-azure GPU=all         # egress lock + 12h compute clock + agent
```

Preemptible hosts: `sudo bash ops/host-resume/install.sh` (after editing
`/etc/mtbench-resume.env`) so a reboot auto-resumes through the same launcher.

## Score a submission

```
cd bench/scorer
python3 prepare_test.py testdata/           # ONCE, online: newstest2014 -> testdata/ (host-only)
IMAGE=mtbench-container SEED=<seed> DECODE_BUDGET=3600 ./score.sh <state>/workspace
```
→ `result.json`: `test_bleu`, `sacrebleu_sig`, decode time, artifact bytes, canary check.

## Runtime-verify TODO (needs a docker + GPU host)

1. `make image` builds; `load_dataset('wmt/wmt14','de-en')` resolves (datasets 4.8.5).
2. Agent honors `HTTPS_PROXY`, else fail-closed holds — preflight egress test.
3. `--network none --gpus` decode of a real artifact end-to-end through the scorer.
4. A preempt → reboot → `host-resume` → clock-continues cycle.
