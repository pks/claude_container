# PLAN — open task, collaborating agents (collab arm)

Train the best **English→German** translation model you can, **from scratch**, and maximize its
**BLEU** on a held-out test set scored once. Architecture, data cleaning, and recipe are yours —
devising them is the task. **You are one of four agents working the same problem at once, and you
can share results, ideas, and code with the others.**

> Two-arm study: this is the **collab** arm. The **solo** control arm ships this same plan with the
> "Collaborate" section removed and no `/collab` mounted. Everything else is identical.

## Goal
- EN→DE, WMT14 news. Headline: **test BLEU** (newstest2014), reported as a **Pareto point**
  (BLEU × model size × decode cost), not one scalar.
- Submit **one** final system (an ensemble of your own models counts as one).

## Environment
- **1 GPU, yours** (`CUDA_VISIBLE_DEVICES` is pinned for you). Peers hold the other three.
- **Wall-clock budget** (not per-agent compute time) — all four run concurrently. Keep the
  deliverable current; there is no clock-pause.
- Data: **WMT14 EN–DE at `$MTBENCH_DATA`** (`datasets.load_from_disk` → `train` + `validation`).
  `validation` = **newstest2013** = your dev set. Test = **newstest2014**, withheld.
- Network is available (no airgap) — but see Rules.

## Rules (violating any voids the run)
1. **From scratch** — random init only; no pretrained weights/embeddings/checkpoints.
2. **No external data** — only the provided bitext; no extra corpora, back-translation, or
   distillation from any external/pretrained model.
3. **No test peeking** — do not fetch, reconstruct, or memorize newstest2014 source or references.
   (Honor-enforced + a post-hoc contamination canary; a flagged run is void.)
4. **Submit a runnable system, not translations** — the harness runs it on the withheld test.
5. **Pinned dev metric (so leaderboard numbers are comparable):** report dev-BLEU on the **full**
   newstest2013 (no subsets), sacreBLEU **`nrefs:1|case:mixed|eff:no|tok:13a|smooth:exp`**.

## Collaborate — the shared blackboard (`/collab`)
A git-synced shared dir. **Only ever write your own shard** (`<agent>.jsonl`, `code/<agent>/…`);
never edit another agent's files. Tools (already on PATH):

- **`collab-view`** — pull + see the merged leaderboard (sorted; `--pareto` for the frontier;
  `--board` for ideas; `--all`). **Run this before you start anything.**
- **`collab-post`** — post a result after **every** dev eval:
  `collab-post --run <id> --arch <AR|CMLM|DAG|…> --dev-bleu <x> --params-m <m> --T <t> --infer-ms <ms> --recipe code/<agent>/<id> --notes "…"`
- **`collab-say`** — post an idea/finding/question: `collab-say --msg "…" [--to <agent>] [--reply <id>] [--ref <run>]`.
- **Code:** keep recipes in `code/<agent>/…`; the `--recipe` pointer links a number to the exact
  code. **Fork freely** — read `code/<peer>/…`, copy, improve (cite the source run in `--notes`).
  Promote broadly-useful assets (data filter, tokenizer, a fixed kernel) to `shared/` (add-only).

### Protocol
1. `collab-view --all` → what's winning, what's on the frontier, what's untried, recent ideas.
2. **Claim a lane** — write your intended direction to `claims/<agent>.md` (and `git add/commit/push`
   it) so peers don't duplicate you. Prefer an **uncovered region** of the Pareto space.
3. Run your experiment (code in `code/<agent>/…`).
4. After each dev eval: **`collab-post`** the numbers, **`collab-say`** the insight
   (what worked, what to avoid, what a peer should try).
5. Build on peers: reproduce/extend a promising `code/<peer>/…` recipe on your GPU.
6. **Cold-start:** if the board is empty when you begin, pick a *distinct* baseline — don't all
   train the same thing. (Starts are staggered to help.)

Your private `/workspace` stays private — you share by posting to `/collab`.

## Deliverable — `submission/` (self-contained)
- **`model/`** — weights, tokenizer/BPE, config.
- **`decode.sh <src.txt> <hyps.txt>`** — one source line in → one German line out, **line N ↔ line
  N**, offline + deterministic, relative paths, finishes the test within the decode budget (~1 h).
  **Common contract** (so recipes are combinable): read `src` arg 1, write `hyps` arg 2, no extra
  I/O — lets any subset of models be ensembled at the wire.
- **`from_scratch.json`** — random-init seed(s) + attestation.
- Root **`RESULTS.md`** (dev-BLEU-vs-time, config, decode) + **`STATUS.md`** (state + resume).
- Keep `submission/` current — a hard stop takes whatever exists.

## Scoring
- Test BLEU (sacreBLEU `13a`) on withheld newstest2014, computed once by the harness.
- Reported as a **Pareto point** (test BLEU, model size, decode T / time). Best-single per agent,
  plus a top-K ensemble across the pooled recipes.
- Contamination canary + rule audit; violations void or penalize.
