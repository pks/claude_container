# MachineTranslationModelingBench — Task Card (v0)

You are given a GPU, a 12-hour wall clock, and a raw parallel corpus. **Train the
best English→German machine-translation model you can from scratch, and maximize
its BLEU on a held-out test set you get to score exactly once.**

This card states the goal, the rules, and how you are scored. It deliberately does
**not** tell you the architecture, hyperparameters, data cleaning, or training
recipe — devising those is the task.

## Goal

- Translate **English → German**, WMT14 news domain.
- Headline metric: **test BLEU** (newstest2014). Reference line: a from-scratch
  Transformer-base reaches ≈ **27** (Vaswani et al., 2017) — target, not a ceiling.
- You may train **as many models as you want** within the time budget; you submit
  one final system for the single test read (an ensemble of your own models counts
  as one system).

## Environment

- **1 × A100-80GB, uncapped.** No other accelerators.
- **12 hours of compute time, hard.** The budget counts *active* time (train +
  dev-tuning + producing your deliverable). The host may be **preemptible**: if it
  is reclaimed, your run is checkpointed, the clock **pauses**, and you are
  **resumed** later from your workspace — downtime does not cost budget. So expect
  possible interruptions; keep `model/`+`decode.sh` current and your STATUS/resume
  notes fresh so a resume continues cleanly. (The final test decode runs on the
  harness after you submit, not on your clock.) No extensions past the 12h active.
- **Offline environment.** No internet except your own reasoning endpoint. Every
  library, dataset, and tool you may need is already in the image — you cannot
  `pip install`, download models, or fetch data mid-run, so don't try. If something
  you expect is missing, work with what's baked in.
- Harness, image, and tooling: the provided container (`claude_container`). Host-
  specific paths, credentials, and launch details are in the **HOST-\*** file, not
  here — this card is environment-agnostic.

## Data

- **WMT14 EN–DE is baked at `$MTBENCH_DATA` (`/opt/mtbench/wmt14`).** Load with
  `datasets.load_from_disk("$MTBENCH_DATA")` → splits **`train`** and
  **`validation`** (= newstest2013 dev). Read pairs from the dataset object.
- **Only train + dev exist. No test split is present** (see Test protocol), and the
  environment is offline so you cannot fetch anything else.
- **Cleaning/filtering/tokenization are yours to decide.** No preprocessing is done
  for you; deciding what to keep is part of the task. No pretrained model is
  available to filter with (rule 1) — heuristics or self-trained only.
- **dev = newstest2013** (the `validation` split, full references — tune freely).
- **test = newstest2014 — entirely withheld.** You never see the test source or
  references. You submit a runnable system; the harness decodes the test with it and
  scores it (see Test protocol). Select your final system on dev alone.

## Rules (hard constraints — violating any voids the run)

1. **From scratch.** No pretrained weights, embeddings, or checkpoints of any kind.
   Random init only. (The harness may inspect your init.)
2. **No external data.** Only the provided WMT14 EN–DE bitext. No other parallel or
   monolingual corpora, no back-translation from external models, no distillation
   from any pretrained/external model.
3. **No reference lookup.** Do not fetch, reconstruct, or memorize newstest2014
   references from any source. You translate the test **source**; the harness holds
   the references.
4. **You submit a runnable system, not translations.** You never produce or see the
   test output; the harness runs your system on the withheld test and scores it. Any
   self-reported test number is ignored.
5. **Any architecture is allowed** (AR, NAR, diffusion, DAG, …) — anything you train
   yourself under rules 1–2. Ensembles of your own models are fine (one system),
   subject to the size cap below.

## Test protocol (the harness runs your model — you never see the test)

- Tune and iterate on **dev** as much as you like; pick your final system on dev.
- You deliver a **model artifact + `decode.sh`** (below). The harness invokes it on
  the **withheld** test source and computes BLEU — **once**. You never see the test
  source, so you cannot translate it yourself, hand-craft outputs, or peek.
- The harness mixes **synthetic canary lines** into the source it decodes and strips
  them before scoring; a system that special-cases inputs instead of translating
  will show up there.

## Deliverables

Assemble a **self-contained `submission/` directory** in your workspace. **The
harness mounts ONLY `submission/` and nothing else** — so everything decode needs
must be inside it, and the **10 GB cap is measured on the whole `submission/` dir**
(nothing outside counts or is reachable; you cannot stash weights in `ckpt/` to
dodge the cap). Contents:

- **`submission/model/`** — weights, tokenizer/BPE, config: everything to translate.
- **`submission/decode.sh <source.txt> <hyps.txt>`** — reads one raw source sentence
  per line, writes one German hypothesis per line. **Output line N must be the
  translation of input line N** — if you batch or length-sort internally, restore the
  original order before writing, or your score silently collapses. Must run
  **offline, no network at all, deterministically**, using only baked-in deps + files
  **inside `submission/`**. **Use paths relative to `submission/`** (it is mounted at
  a different location than `/workspace`; absolute `/workspace/...` paths won't exist).
  Any model code decode.sh imports must also live inside `submission/`. Finish within
  the decode-time budget in the HOST file. This is the only thing the harness runs to
  score you — if it doesn't run, you don't score.
- **`submission/from_scratch.json`** — attestation: random-init seed(s) + a note that
  the model was trained from scratch on the provided bitext only.
- **`RESULTS.md`** (dev-BLEU curve over compute time, final config, decode settings) and
  **`STATUS.md`** (live state + resume notes) at the workspace root.
- Keep `submission/` **current as you go** — a hard stop at the budget takes whatever
  exists; don't leave it for the last minute.

## Scoring

- **Primary:** test BLEU (sacreBLEU, signature
  `nrefs:1|case:mixed|eff:no|tok:13a|smooth:exp`), computed by the harness.
- **Secondary (Pareto):** BLEU vs wall-clock — your dev-BLEU-over-time curve, so a
  model that reaches good BLEU fast is distinguished from one that needs the full
  12 h. The reported result is the **(test BLEU, train wall-clock)** point plus the
  dev curve, not a single scalar. Harness-measured **decode time** is reported
  alongside (inference cost).
- **Integrity:** harness-computed score is authoritative; self-reported/test-peek/
  rule violations are penalized or void the run.

## Optional variant — reproduce Transformer-base

Same rules, but constrain the system to a **standard autoregressive Transformer-base**
(Vaswani et al., 2017: 6+6 layers, d=512, 8 heads, ffn 2048, ~65M params) and report
how close you land to the paper's ≈27. A sharper, known-achievable target than the
open track.

## Deliberately unspecified (this is what's being measured)

Architecture · depth/width · tokenization · vocab size · data filtering · batch
size · optimizer · LR schedule · regularization · number of models · decode strategy
(beam, length penalty, ensembling, …) · how you spend the 12 h. No recipe is
provided; producing one that works is the benchmark.
