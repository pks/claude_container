# MachineTranslationModelingBench — Task Card (v0)

**Train the best English→German MT model you can, from scratch, and maximize its
BLEU on a held-out test set scored exactly once.** Architecture, hyperparameters,
data cleaning, and recipe are up to you — devising them is the task.

## Goal

- EN→DE, WMT14 news. Headline metric: **test BLEU** (newstest2014).
- Reference line: from-scratch Transformer-base ≈ **27** (Vaswani et al., 2017) —
  a target, not a ceiling.
- Train as many models as you want; submit **one** final system (an ensemble of your
  own models counts as one).

## Environment

- **1 × A100-80GB, uncapped.**
- **12 h of compute time, hard** (active time only). Host may be **preemptible**:
  on reclaim you're checkpointed, the clock pauses, and you resume from your
  workspace — downtime is free. Keep the deliverable + STATUS current so resume is
  clean. Final test decode runs on the harness, not your clock.
- **Offline** except your reasoning endpoint. No `pip install` / downloads / data
  fetches — everything is baked in.
- Host paths / credentials / launch details: see the **HOST** file.

## Data

- **WMT14 EN–DE at `$MTBENCH_DATA`** (`/opt/mtbench/wmt14`):
  `datasets.load_from_disk(...)` → `train` + `validation` (= newstest2013 dev).
- **No test split present** (withheld); offline, so nothing else to fetch.
- Cleaning / filtering / tokenization are yours. No pretrained model to filter with
  (rule 1) — heuristics or self-trained only.
- **dev = newstest2013** (`validation`, full refs — tune freely). Select on dev.
- **test = newstest2014**, withheld — you never see source or refs.

## Rules (violating any voids the run)

1. **From scratch** — random init only; no pretrained weights/embeddings/checkpoints.
2. **No external data** — only the provided bitext; no extra corpora, back-
   translation, or distillation from any external/pretrained model.
3. **No reference lookup** — don't fetch/reconstruct/memorize newstest2014 refs.
4. **Submit a runnable system, not translations** — the harness runs it on the
   withheld test; self-reported test numbers are ignored.
5. **Any architecture** (AR/NAR/diffusion/DAG/…) you train yourself. Ensembles OK
   (one system, within the cap).

## Test protocol

Iterate on dev; the harness runs your system on the **withheld** test source and
scores BLEU **once** — you never see the test, so you can't hand-craft or peek. The
harness mixes **canary lines** into the decode input (stripped before scoring) to
catch input special-casing.

## Deliverable — `submission/` (self-contained)

The harness mounts **only** `submission/`; the **10 GB cap is on the whole dir**
(nothing outside is reachable or counts — can't stash weights in `ckpt/`). Contents:

- **`model/`** — weights, tokenizer/BPE, config.
- **`decode.sh <src.txt> <hyps.txt>`** — one source line in → one German line out.
  **Output line N ↔ input line N** (restore order if you batch/sort, else score
  collapses). Runs **offline, deterministic**, using only baked deps + files inside
  `submission/`, **relative paths** (mounted elsewhere than `/workspace`). Must finish
  within the HOST decode budget. If it doesn't run, you don't score.
- **`from_scratch.json`** — random-init seed(s) + from-scratch attestation.
- At workspace root: **`RESULTS.md`** (dev-BLEU-vs-time, config, decode) +
  **`STATUS.md`** (state + resume notes).
- Keep `submission/` current — a hard stop takes whatever exists.

## Scoring

- **Primary:** test BLEU (sacreBLEU `nrefs:1|case:mixed|eff:no|tok:13a|smooth:exp`),
  computed by the harness.
- **Secondary (Pareto):** dev-BLEU-vs-compute-time curve — reported as
  **(test BLEU, train time, decode time)** + the curve, not one scalar.
- **Integrity:** harness score is authoritative; peeking / self-reporting / rule
  violations void or penalize.

## Optional variant — reproduce Transformer-base

Same rules, constrained to a standard AR Transformer-base (6+6, d=512, 8 heads,
ffn 2048, ~65M) — report how close to ≈27. Sharper, known-achievable target.

## Deliberately unspecified (the point)

Architecture · depth/width · tokenization · vocab · filtering · batch size ·
optimizer · LR schedule · regularization · #models · decode (beam, LP, ensembling) ·
how you spend the 12 h. Producing a recipe that works is the benchmark.
