# Collaborative-agents experiment — design spec (draft)

## Question
Does a **team of agents that share results, ideas, and code** beat the **same number of
independent agents** at the same compute? The project's prior findings ("process beat ideas,"
convergent rediscovery, large agent-to-agent variance) make collaboration the natural next
meta-question.

## Setup
- **Open plan** (maximize test BLEU, WMT14 EN→DE, from scratch, any architecture AR/NAR, ensemble
  = one system). Not the constrained diffusion/DAG plans — go back to the free plan.
- **4 agents, 1 per GPU, across 2 local hosts:** `titan` (2× TITAN RTX, 24 GB, Turing, fp16-only)
  + `titan2` (2× RTX A6000, 48 GB, Ampere, bf16). Heterogeneous — fine (adds diversity); small
  throttled models fit everywhere, so cross-agent recipe reuse stays viable.
- **No airgap.** Agents have network: they run git themselves, and may look things up. Consequence:
  BLEU is a **relative** signal (collab vs solo), not a certified from-scratch absolute. Guard with a
  post-hoc **contamination canary** (diff submitted hyps against known newstest2014 refs; flag suspicious
  exact matches / the harness canary lines).
- **Wall-clock cap per arm** (not the solo compute-clock — real-time collaboration is wall-coupled).
  Run in the **320 W window** (weekday nights 20:00–05:00 UTC + weekends); at 100 W these GPUs are ~5×
  slow and agents can't iterate enough to collaborate. Suggested cap: 12 h wall, 4 GPUs concurrent.

## Two arms (matched)
- **Arm A — collaborate:** all 4 share the git `/collab` repo (below).
- **Arm B — control:** same plan, hardware, budget; **no `/collab`** — 4 isolated solo runs.
- Same everything else. Run sequentially. Compare: best final test BLEU, Pareto (BLEU × params × T),
  approach diversity, time-to-first-good-result, did collaboration actually happen, cost.

## Sharing = a shared git repo (agents do git directly; no airgap → no host daemon)
**Bare repo = `titan:~/exp/diffusemt_meta/collab_v0.git`** (created; no root — titan is the
always-on control host; gitignored from the diffusemt_meta tree). titan's 2 agents clone via the
local path / host LAN (`10.10.20.21`); titan2's 2 over Tailscale (`titan2.tailcd9e.ts.net` mesh,
ssh works both ways). Containers inherit host routing → reach it with no airgap. Layout —
**per-agent shards → zero merge conflicts:**

```
/collab/
  leaderboard/agent-{0..3}.jsonl   # RESULTS   (collab-post)
  messages/agent-{0..3}.jsonl      # IDEAS     (collab-say; reply_to / to)
  code/agent-{0..3}/...            # CODE      (recipes, scripts, configs)
  shared/                          # promoted common assets (data prep, tokenizer, fixes) — add-only
  claims/agent-{0..3}.md           # lane-claiming (anti-dup)
```

### Leaderboard entry schema (one JSON line / experiment)
```json
{"agent":"agent-2","ts":"2026-08-12T21:03Z","run":"dag-glat-v3","arch":"DAG",
 "dev_bleu":22.9,"params_m":63.0,"size_mb":240,"decode_T":1,
 "infer_ms_sent":4.2,"throughput_sent_s":5300,"gpu":"A6000",
 "recipe":"code/agent-2/dag-glat-v3/","notes":"self-distill +0.9; plateaus"}
```
Comparable axes = **dev-BLEU × params × decode-T** (hardware-agnostic). `infer_ms_sent` is
GPU-dependent → keep but **GPU-tagged**, informational.

### Comparability guards (in the plan)
- dev-BLEU pinned: `validation` = newstest2013, full-dev (no subsets), sacreBLEU `13a`
  (`nrefs:1|case:mixed|eff:no|tok:13a|smooth:exp`).
- recipe pointer links every number → the exact code that made it ("reproduce the winner" = one `cp -r`).

### Tools (in the harness image)
- `collab-post …`   → validate + append result to own shard, `git add/commit/push` (pull-rebase on race).
- `collab-say …`    → append message to own shard, push. `--to`, `--reply`, `--ref`.
- `collab-view [--pareto|--board]` → `git pull`, read ALL shards, render sorted + Pareto leaderboard
  and the merged time-sorted message feed to stdout. **Local read-only render** (no committed
  LEADERBOARD.md → nothing to conflict).
- code sharing = write files into `code/agent-N/`, pushed by the next `collab-post`/explicit `collab-push`.

## Open plan — Collaboration protocol (appended to the plan)
1. `collab-view` first — see what's winning / on the frontier / untried; read recent ideas.
2. **Claim a lane** (`claims/agent-N.md`) — reduce collision.
3. Run your experiment; keep code in `code/agent-N/`.
4. After each dev eval: `collab-post` the numbers + `collab-say` the insight ("X failed because Y",
   "someone try Z").
5. Build on others: read/fork `code/agent-X/`, cite it; promote reusable wins to `shared/`.
6. **Cold-start:** stagger starts ~20 min so later agents see early results (else all train the same
   baseline first).
- Private `/workspace` stays private — you share by *posting to `/collab`*.

## Deliverable + scoring
One final system per agent (ensemble of your own models OK). At the wire, score each arm on withheld
newstest2014, once: report **best-single** and, for Arm A, an **ensemble of top-K shared recipes**
(reproduced/combined — requires the plan's common decode contract). Plus collaboration telemetry
(leaderboard reads, code forks, ensemble composition, time-to-first-good) and cost.

## Build components (extends claude_container)
- `ops/collab-launch.sh` — launch 2 agents/host, GPU-pinned (`CUDA_VISIBLE_DEVICES`), `/collab`
  clone bind-mounted, **no proxy**. Two-arm switch (A mounts `/collab`, B doesn't).
- `collab-post` / `collab-say` / `collab-view` — baked into the image; git-backed.
- `collab/PLAN-collab.md` — open plan + the protocol above (staged into `plan/` at launch, like bench).
- Bare repo init + per-host clone + ssh access for the container user.
- Scoring: reuse `bench/scorer`; add the contamination canary + Pareto/ensemble reporting.

## Open items
- Exact wall-clock cap + which 320 W window to schedule.
- Cross-agent ensemble: mandate a common `decode.sh`/model I/O contract in the plan (so any subset of
  reproduced recipes ensembles), or score best-single only. (Without a meta agent, ensemble assembly
  falls to the harness at the wire, or to whichever peer packages it.)
- Stagger + lane-claiming: enough to avoid cold-start dup, or add a light "reserve a region" convention?

## Parked
- **Meta / submission-manager agent** — a 5th, non-training agent owning the deliverable
  (keeps a valid current-best submission, curates a diverse top-K ensemble, guards validity +
  contamination). Fixes the peer design's "who ships?" gap and the unbanked-at-the-wire failure
  (bench cohort-B). **Parked: it needs a GPU for ensemble decode, and only 4 GPUs exist** (all on
  training peers). Revisit if a 5th GPU / spare decode slot appears, or if the harness does the
  ensemble deterministically instead. If added, put it in **both arms** (else it confounds the
  collaboration signal).
