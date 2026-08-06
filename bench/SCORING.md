# MachineTranslationModelingBench — Harness & Scoring Spec (v0)

Operator-facing (the agent sees only `TASKCARD.md`). en→de, WMT14.

## Isolation

- **Compute:** 1 × A100-80GB, uncapped. Preemptible OK — the budget is *compute
  time*, not wall (below), so preemption doesn't confound the score.
- **Egress deny-all except the inference endpoint.** Agent on an `--internal` docker
  net (no route out) → allowlist proxy → the one model-API host. Enforces by
  construction: from-scratch, no external data, no ref lookup, no `pip install`.
- **Offline tooling:** the image bakes every MT lib/tool (torch, sentencepiece,
  subword-nmt, sacrebleu, tokenizers, fast_align, …) + `*_OFFLINE=1`, no `HF_TOKEN`.

## Data placement (load-bearing)

- **In the agent image:** WMT14 **train** + **dev** (newstest2013) only. No test data.
- **Only in the external scorer:** **test** (newstest2014) source + refs, and canaries.
- Why: `wmt/wmt14` ships test refs; baking the full dataset would leak them via a
  file read regardless of network. Test stays out of the agent container entirely.

## Submission → scoring flow

1. Take the agent's **`submission/`** (self-contained: `decode.sh` + `model/` + code).
2. **Pre-checks (fail → void):** `du -sb submission/` ≤ **10 GB** (whole dir; only it
   is mounted); `decode.sh` executable + `model/` present; advisory provenance scan.
3. **Decode input:** test source (N) + **K canaries** at known positions, shuffled
   with recorded permutation → `decode_input.txt` (N+K). decode.sh sees only this.
4. **Run locked down:** same image, mount ONLY `submission/` (ro) + tmpfs, **no
   network**, dropped privileges (`--user` non-root, `--cap-drop ALL`,
   `no-new-privileges`, `--pids-limit`), GPU on, `timeout DECODE_BUDGET`. Non-zero
   exit / timeout / wrong line count → void.
5. **Un-permute, strip canaries** → N hyps aligned to refs.
6. **Score once:** sacreBLEU `nrefs:1|case:mixed|eff:no|tok:13a|smooth:exp`.

No second submission; the read is the harness's.

## Canaries

K lines mixed into the decode input, excluded from scoring: (a) the agent can't tell
which lines count → no selective memorization/hand-crafting; (b) tripwire — a real
NMT model vs an LLM-passthrough vs a lookup table handle them differently.
**Sampled from real dev source** so they're indistinguishable from test (safe: dev is
excluded from scoring). Fallback: word-salad. Regenerate per run.

## Integrity

- **From-scratch:** advisory provenance scan; the real enforcement is the airgap
  (no pretrained weights in the image, none fetchable) + the 10 GB cap + canaries.
- **Submission-only, no-network decode:** a `decode.sh` that phones home fails, and
  nothing outside `submission/` (ckpt/, .venv, logs) is reachable.
- **Self-report ignored:** any test number in `RESULTS.md` is unused; a gap is a flag.
- **Determinism:** decode should be deterministic (harness may run twice).

## Budget

- **Compute time**, not wall: active seconds are persisted (`.bench_elapsed_s`) via a
  heartbeat and capped at `BENCH_BUDGET_S` (12 h); preemption gaps are free; resume
  continues from the persisted total (`ops/host-resume/`).
- `DECODE_BUDGET` (HOST file) bounds step 4 separately — inference cost, not the 12 h.

## Reported result

**(test BLEU, train compute-time, decode time)** + the dev-BLEU-vs-time curve.
Ranking is the Pareto front over (BLEU, time), not one scalar. Ref line ≈ 27.

## Open / later

- COMET as a secondary metric.
- Fresher test set (blunt residual newstest2014 pretraining-memory contamination).
- Multi-seed replication to measure variance.
