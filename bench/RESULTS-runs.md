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

**Cohort B (run-5): anchor-free TASKCARD v1** — no reference score named, sole
instruction "maximize BLEU". Image rebuilt with `PI_OFFLINE=1` (npm phone-home
pings silenced). Ran to test the anchor-vs-ceiling question (finding 2): opus
**still self-capped training ~9.3 h** and landed **26.80** (low end of its own
band) — removing the "≈27" reference did **not** push it toward 28. Verdict:
the self-cap is genuine early-convergence (lr floor + flat ppl), **not
anchoring**.

- **-01 = opus-5** (anthropic), **-02 = gpt-5.6-sol** (openai).

**Provenance (cohort A):** repo HEAD `1b89bca` at last build; bench image
`mtbench-container` built **2026-08-08T06:31 UTC** (both nodes); pi-coding-agent
**0.84.1**; TASKCARD **v0 (anchored)** throughout. Runs 1–2 predate a few
harness-tooling commits (scorer/cost) made mid-cohort, but the agent-facing
image + TASKCARD were unchanged; those commits only affect scoring/cost
recovery, not agent behavior. Anchor-free card is **v1** (`f8a7700`);
`PI_OFFLINE=1` (suppress npm phone-home pings) added after cohort A.

**Provenance (cohort B, run-5):** anchor-free TASKCARD **v1** (`f8a7700`,
"maximize BLEU", no reference score); image rebuilt with **`PI_OFFLINE=1`**
(verified 0 ping noise in logs); pi-coding-agent **0.84.1**; both runs completed
the full **43200 s** compute clock, `.bench_done` at 21:58/21:59 UTC
2026-08-10; scored `nrefs:1|case:mixed|eff:no|tok:13a|smooth:exp|version:2.6.0`,
100/100 canaries non-empty, test ≥ dev both.

## Scoreboard — test BLEU @ inference $

| run | opus (-01) | gpt (-02) | winner |
|----:|-----------|-----------|--------|
| 1 | **27.44** / $7.57 | 25.28 / $5.72 | opus +2.16 |
| 2 | 26.74 / $5.92 | — (preempted ×2, never completed) | opus (only finisher) |
| 3 | **27.03** / $9.61 | 26.93 / $3.31 | opus +0.10 |
| 4 | 26.86 / $5.83 | **26.92** / $1.98 | **gpt +0.06** |
| 5† | **26.80** / $6.08 | 25.85 / $2.90 | opus +0.95 |
| **mean** | **26.97** / $7.00 (5 runs) | **26.25** / $3.48 (4 done) | — |

† Run 5 = **cohort B, anchor-free card**. All others anchored (cohort A).

gpt's r1 (25.28) + r5 (25.85) drag its mean; its two middle runs (26.93, 26.92)
sit dead-even with opus at ~half the cost. opus's band stays tight (26.74–27.44,
~0.7 BLEU) across both the anchored and anchor-free cards.

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
| 5 | opus | 26.80 | 26.30 | 6.08 | 486 MB | 21s | big (6+6, d1024), **`--time-budget 9.3`** (self-capped) + **avg-of-8** ckpt, decode-α sweep; **anchor-free card** |
| 5 | gpt | 25.85 | 25.40 | 2.90 | 498 MB | 68s | **11.2 h** train to the wire, 124k steps, single ckpt (no avg), packaged at wire |

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

2. **opus self-caps training early — and it's convergence judgment, NOT anchoring
   (settled r5).** Every run it stopped training ~8–9.5 h (r4 `--max-hours 8.3`,
   r5 `--time-budget 9.3`), ~25–30 % of the compute budget not spent on training.
   Hypothesis was anchoring/satisficing to the card's "≈27" reference. **Run 5
   removed that anchor (v1 card) — opus still capped ~9.3 h and landed 26.80, the
   low end of its own band, not higher.** So the "27" number wasn't the cause: the
   cap is a genuine convergence call (lr already at floor, ppl flat ~14). The extra
   ~2.7 h wouldn't buy the 27→28 BLEU; the wall is data+model, not willingness to
   spend. (opus does spend the freed time on ckpt-averaging + decode tuning, not
   idle.)

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
- Anchor-free cohort (r5, `f8a7700` card + `PI_OFFLINE=1` image): **done — opus
  still self-caps, real ceiling** (finding 2). No further anchor A/B needed.
