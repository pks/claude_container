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
python3 prepare_test.py testdata/           # ONCE, online: newstest2014 + dev.src -> testdata/ (host-only)
IMAGE=mtbench-container SEED=<seed> DECODE_BUDGET=3600 ./score.sh <state>/workspace/submission
```
→ `result.json`: `test_bleu`, `sacrebleu_sig`, decode time, submission bytes, canary check.
The scorer mounts ONLY `submission/` (10 GB cap on the whole dir), runs `decode.sh`
locked down (`--network none`, non-root, caps dropped, tmpfs scratch), and draws
canaries from real dev source so they're indistinguishable from test.

## Runtime verification (done on a docker + GPU host, 2026-08-06)

1. ✅ **Data resolve + test-exclusion** — `load_dataset('wmt/wmt14','de-en')` resolves
   under datasets 4.8.5 with **no `trust_remote_code`**; `save_to_disk` keeps
   train(4,508,785)+validation(3,000), test excluded (structural). Caught + fixed a
   real bug: HF names the test file `wmt14-test.arrow`, not `newstest2014`, so the
   build assertion's pattern was useless — corrected + verified (passes clean, catches
   a stray `wmt14-test.arrow`).
2. ✅ **Egress fail-closed** — from an `--internal` network the real image gets **no
   internet and no DNS** (`BLOCKED` / `NO-DNS`), so a client ignoring the proxy leaks
   nothing. (tinyproxy allowlist *forwarding* still wants a check on the built image;
   fail-closed is the guarantee regardless.)
3. ✅ **Scorer end-to-end through docker** — full pipeline (dev-sourced canaries →
   shuffle → locked `--network none` decode → strip → sacreBLEU, correct signature),
   void on wrong line count, and the **HIGH isolation fix confirmed**: decode could not
   read a file outside `submission/`.
4. ✅ **Compute-clock + resume** — clock fairness (active-only, preemption gap free,
   caps at budget) proven in isolation; auto-resume guards (skip on `.bench_done`,
   skip on live agent container, proxy excluded) verified.

Remaining (need a full 12 h run / built image, not blockers): a real-model GPU decode,
and tinyproxy allowlist forwarding on the built `mtbench-container`.
