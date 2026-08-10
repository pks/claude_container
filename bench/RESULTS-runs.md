# MachineTranslationModelingBench — Run Log

WMT14 EN→DE, from scratch, 12 h compute / 1×A100-80, airgapped-except-inference.
Test = newstest2014, scored once by the harness with sacreBLEU
`nrefs:1|case:mixed|eff:no|tok:13a|smooth:exp` (v2.6.0). Cost = **inference only**
(pi agent tokens, from the persisted session usage); add ~24 A100-hr GPU per
two-node cohort.

**Cohort A (runs 1–4): anchored TASKCARD v0** — card showed "from-scratch
Transformer-base ≈ 27 (Vaswani 2017)" as a reference line + a "reproduce
Transformer-base ≈27" optional variant. Those anchors were removed in `f8a7700`
after run-4; subsequent cohorts use the anchor-free card.

- **-01 = opus-5** (anthropic), **-02 = gpt-5.6-sol** (openai).

**Provenance (cohort A):** repo HEAD `1b89bca` at last build; bench image
`mtbench-container` built **2026-08-08T06:31 UTC** (both nodes); pi-coding-agent
**0.84.1**; TASKCARD **v0 (anchored)** throughout. Runs 1–2 predate a few
harness-tooling commits (scorer/cost) made mid-cohort, but the agent-facing
image + TASKCARD were unchanged; those commits only affect scoring/cost
recovery, not agent behavior. Anchor-free card is **v1** (`f8a7700`);
`PI_OFFLINE=1` (suppress npm phone-home pings) added after cohort A.

## Scoreboard — test BLEU @ inference $

| run | opus (-01) | gpt (-02) | winner |
|----:|-----------|-----------|--------|
| 1 | **27.44** / $7.57 | 25.28 / $5.72 | opus +2.16 |
| 2 | 26.74 / $5.92 | — (preempted ×2, never completed) | opus (only finisher) |
| 3 | **27.03** / $9.61 | 26.93 / $3.31 | opus +0.10 |
| 4 | 26.86 / $5.83 | **26.92** / $1.98 | **gpt +0.06** |
| **mean** | **27.02** / $7.23 (4 runs) | **26.38** / $3.67 (3 done) | — |

gpt's r1 (25.28) drags its mean; its last two (26.93, 26.92) sit dead-even with
opus at ~half the cost.

## Per-run detail

| run | model | test | dev | inf $ | size | decode | strategy |
|----:|-------|-----:|----:|------:|-----:|-------:|----------|
| 1 | opus | 27.44 | 26.88 | 7.57 | 2.4 GB | 55s | 3-model **ensemble**, beam 5, α 0.9 |
| 1 | gpt | 25.28 | — | 5.72 | 232 MB | 50s | lean single, `i%3` ~1/3 subsample |
| 2 | opus | 26.74 | 26.31 | 5.92 | 5.5 GB | — | single **big8** (8enc/6dec, d1024) + ckpt-averaging |
| 2 | gpt | — | — | — | — | — | **preempted twice**, restart reset clock, no deliverable |
| 3 | opus | 27.03 | 26.58 | 9.61 | 5.5 GB | 18s | big (6+6, d1024), finalize + refresh (priciest run) |
| 3 | gpt | 26.93 | 26.10 | 3.31 | 475 MB | 18s | 7.5 h train + resume, 126k steps, packaged at wire |
| 4 | opus | 26.86 | 26.16 | 5.83 | 5.5 GB | 17s | single big (6+6, d1024), **`--max-hours 8.3`** (self-capped) |
| 4 | gpt | 26.92 | 26.47 | 1.98 | 473 MB | 36s | **10.8 h** train to the wire, 205k steps, packaged at wire |

All completed runs: from-scratch attested, 100/100 canaries non-empty (full
coverage, no input special-casing), test ≥ dev (no dev-overfit).

## Findings

1. **Ceiling ≈ 27–28 sacreBLEU-13a, and it's compute+data-bound, not agent skill.**
   Constrained to WMT14 parallel data (no back-translation) the published high is
   Ott 2018 ~29.3 — but that's `multi-bleu`+compound-split (≈ **~28 in 13a**) and
   needed big-batch training across 128 GPUs. In 12 h / 1 A100 a big model is
   undertrained → lands ~27. gpt pushing full compute (10.8 h) still hit ~26.9 →
   the wall is real. SOTA 30–35 requires back-translation (external monolingual
   data), which the bench forbids.

2. **opus self-caps early — forfeits the ~1 BLEU that closes 27→28.** Every run it
   stopped ~8–9.5 h (r4 explicitly `--max-hours 8.3`, ~30 % of compute unused).
   On a compute-bound task that's leaving the decisive resource on the table.
   Consistent with anchoring/satisficing to the card's "≈27" reference (removed
   in `f8a7700` to test this) and/or conservative convergence judgment.

3. **gpt "brute-forces compute" and converged up.** One long train to the wire +
   package-at-the-end. r1 (25.28, aggressive subsample) → r3/r4 (~26.9, full data,
   90k–205k steps). Matches/edges opus at **~1/3–1/4 the cost and ~1/12 the size**.
   The task rewards GPU-hours over cleverness, and gpt spends them.

4. **Efficiency winner: gpt.** Comparable quality (last two runs), far cheaper
   (\$1.98–3.31 vs \$5.83–9.61) and far smaller (≈475 MB vs 5.5 GB).

5. **Preemption is the main operational risk.** gpt-r2 preempted twice (a restart
   reset its clock → no deliverable); both nodes hit a coincident reclaim on
   2026-08-08 (sshd `kex` drop, containers gone, host up). Compute-clock keeps the
   budget fair, but a passive/unbanked agent at preemption time can lose the run —
   gpt banks late by habit (worked r3/r4, cost it r2).

6. **Cache behavior validated across all runs:** opus `cacheWrite1h` = all writes
   (azure-anthropic 1 h-TTL ext firing); gpt `cacheWrite1h` = 0 (OpenAI auto-cache,
   anthropic-only ext correctly untouched).

## Harness notes (this cohort)

- Cost recovered retroactively from persisted pi session jsonl
  (`state/home/.pi/agent/sessions`, bind-mounted → survives container `--rm`);
  `ops/bench-cost.py` sums it, `run-scoring.sh` folds it into `result.json`.
- Scorer runs decode locked (`--network none`, GPU on, only `submission/` mounted);
  sacreBLEU step runs inside the image (`d007843`).
- Next cohort: anchor-free TASKCARD (`f8a7700`). Watch whether opus then uses full
  budget and moves 27→~28 (anchor) or still self-caps ~27 (real ceiling).
