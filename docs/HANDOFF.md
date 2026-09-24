# HANDOFF — collaborative-agents experiment

State as of **2026-09-24**, branch **`collab`**, all changes **uncommitted**. Written so someone
else (or a later session) can pick this up cold.

Design rationale lives in the study repo, at `diffusemt_meta/collab/COLLAB-EXPERIMENT.md`
(moved out of this repo, which carries mechanism only); this file is what is
built, what is not, and what to do next.

---

## 1. What this is

Two-arm study: does a cohort of agents that **share** results, ideas, and code beat the same
number of **isolated** agents at equal compute? Arm A = collab (shared git blackboard at
`/collab`), Arm B = solo control. Everything else matched.

## 2. What is built and verified

**Plan assembly — by concatenation, not text surgery.** `ops/collab-launch.sh` builds
`plan/PLAN.md` as `TASK_DOC` (+ `OVERLAY_DOC` for the collab arm only). The solo arm ships the
task file **byte-identical**, so there is nothing to strip and no way for collab framing to leak.
A launcher guard greps the solo plan for collab words and warns if a task file ever picks any up.

Three interchangeable tasks, in decreasing freedom:

| `TASK_DOC` | constraint | lines |
|---|---|---|
| `<study-repo>/collab/TASK-open.md` | none — any architecture | 62 |
| `<study-repo>/collab/TASK-nat.md` | non-autoregressive submission; nothing else | 78 |
| `<study-repo>/collab/TASK-diffusion.md` | CMLM / absorbing-diffusion only, no AR-teacher KD | 155 |

`<study-repo>/collab/PLAN-collab.md` (34 lines) is the collaboration overlay — cohort line, blackboard tools,
the loop. Task-neutral, so it composes with all three. Default is `TASK-diffusion.md`.

**All three tasks share one inference rule:** the submission is a single model decoded plainly —
no ensembling, MBR, candidate pools, reranking, second scorer, or length beam. Weight averaging
and an architecture's own refinement passes are allowed. **Inference-scoped**: training-time
ensembling/reranking (e.g. to build distillation targets) stays legal. Note this removed the
collab arm's artifact pooling — sharing is now informational only.

**Per-host hardware docs.** `plan/HOST-titan.md` (TITAN RTX, Turing, no bf16, 280 W) and
`plan/HOST-titan2.md` (A6000, Ampere, bf16, 300 W) each describe **one** card; the launcher picks
by `hostname -s`. Agents see one GPU and are told about one GPU.

**No wall clock.** `WALL_HOURS=none` (or `0`) removes the `timeout` wrapper entirely; default is a
**72 h backstop**, non-numeric values are rejected at launch. Tasks say "done when dev plateaus,
not when a timer fires."

Verified: all 6 task×arm renders assemble with no unsubstituted tokens and 0 collab references in
solo; every CLI flag the overlay names exists in `ops/collab/*`; `bash -n` clean on the launcher.

## 3. Blockers before a run

1. ~~**Wipe `collab_state/`.**~~ **Done 2026-09-24.** The pilot's two state dirs (30 GB) were
   archived to `/storage/archive/pks/diffusemt_meta/attempts/collab-v0_pilot/state/` and removed
   from this repo, so there is nothing left here for the launcher to mistake for a fresh run.
   Checksum-verified before deletion. Keep it that way: the launcher only seeds a state dir when
   `workspace`/`home` are missing, so a leftover dir would silently hand the next agent the old
   `doc/PLAN.md`, workspace and `/collab` clone, and the new plan would never land.
2. ~~**Reset the blackboard.**~~ **Done 2026-09-24**, by archiving rather than resetting in place.
   The pilot's bare repo is now
   `/storage/archive/pks/diffusemt_meta/attempts/collab-v0_pilot/blackboard.git` (same `main`,
   21 commits) — read it for the pilot's history, never launch into it: it holds agent-0/agent-1
   leaderboard rows, messages, wiki fragments, and `code/agent-1/ar-base/`, an **autoregressive**
   recipe sitting in the fork-freely dir, i.e. a ready-made paradigm violation, plus numbers from
   a differently constrained task.

   `COLLAB_BARE` now defaults to `~/exp/diffusemt_meta/.work/collab.git` — gitignored scratch, and
   it narrows git-daemon's `--base-path` from the whole study repo to that one directory. **Create
   it before the first launch**, and create a fresh one per run:
   ```sh
   git init --bare ~/exp/diffusemt_meta/.work/collab.git   # then re-seed the skeleton dirs
   ```
   `GIT_URL`'s basename is derived from `COLLAB_BARE`, so the two cannot drift apart; override
   only the host part. To render the pilot's wiki:
   `make wiki COLLAB_BARE=/storage/archive/.../collab-v0_pilot/blackboard.git`.
3. **git-daemon needs rebinding before a cross-host cohort.** The long-running one from
   2026-09-08 was **killed on 2026-09-24**: it was still serving `<study-repo>/collab_v0.git`,
   which had just been archived, so it answered nothing. Nothing listens on 9418 now. Start a
   fresh one with `ops/collab-launch.sh daemon` once the new blackboard exists — the launcher
   derives `--base-path` from `COLLAB_BARE`, so it is scoped to `.work/` rather than the whole
   study repo, which the old one had.

   Binding: the old one was on docker0, reachable from containers on titan, invisible to titan2.
   Set `DAEMON_LISTEN` to whatever the agents reach the host on. A titan-only
   2-agent run works; a 4-agent cohort does not until it is rebound. **Security note:**
   `--enable=receive-pack` with `--export-all` is *anonymous unauthenticated write*. On docker0
   that is container-local; rebinding to bond0 or 0.0.0.0 exposes it to the whole LAN. Scope it to
   the specific address with `DAEMON_LISTEN`, keep `--strict-paths`, and stop the daemon when the
   run ends.

**Also unverified:** titan2's sshd refuses `:22` on both the LAN address and the Tailscale name,
so its image, repo checkout, and `claude` login could not be checked from titan. Get on that box
before planning a 4-agent run.

## 4. Launch

```sh
# once on the git host (titan)
ops/collab-launch.sh daemon

# titan, collab arm, Claude Code on the host subscription
ARM=collab PROFILE=claude IMAGE=collab-container WALL_HOURS=none \
  GIT_URL=git://$GIT_HOST/collab.git \
  ops/collab-launch.sh agent-0:0:TITAN agent-1:1:TITAN

# solo control — same everything, no /collab, plan = the task file alone
ARM=solo PROFILE=claude IMAGE=collab-container WALL_HOURS=none \
  ops/collab-launch.sh agent-0:0:TITAN agent-1:1:TITAN
```

Switch task with `TASK_DOC=$COLLAB_DIR/TASK-nat.md`. For a cross-host cohort pass the **whole** roster
on **both** hosts: `COHORT="agent-0 agent-1 agent-2 agent-3"` — otherwise each host's pair is told
it is a cohort of 2. Both arms must share the `WALL_HOURS` setting or the comparison is unmatched.

Attach: `tmux attach -t collab-agent-0`.

## 5. Decisions still open

- **What ends an arm.** With no cap this is no longer implied by the launch command: a calendar
  date, "all agents plateaued", or an operator call. Must be identical across arms and **recorded
  per agent** — nothing captures it automatically today.
- **Speed as the discriminator.** `T` (decode passes) is the axis agents actually differ on, but
  nothing binds cost — headline is BLEU, so a rational agent spends passes and the discriminator
  collapses. Options discussed, none applied: a second scored row at a fixed pass budget; defining
  `T` as *total decoder forward passes per sentence*. Do **not** assign `T` per agent — the choice
  of where to sit on the curve is the observable.
- **`STAGGER` is collab-only.** Collab agents start 20 min apart (cold-start anti-duplication),
  solo agents all at once. Per-agent budget is identical and staggering is meaningless without a
  board, so this is probably fine — but it is an unmatched difference between the arms, left
  deliberately for a decision.
- **Meta / submission-manager agent** — parked, needs a 5th GPU. See the spec.

## 6. Lessons from the 2026-09-09 pilot

- **Idle agents are the expensive failure.** agent-0 slept through training runs, blew past the
  provider's prompt-cache TTL (cache hit 98% → 0%) and cost ~2× for ~0 output. Every task file now
  forbids long idle sleeps and tells agents to work between short polls.
- **`$MTBENCH_GPU`, not `$COLLAB_GPU`.** The card name must exist in both arms; the old name was
  set only in the collab block and was dead in solo. `collab-post` accepts either.
- **The power cap is real and moves.** 100 W weekdays 05:00–20:00 UTC drops the SM clock to
  ~300 MHz — roughly an order of magnitude off peak, per-step latency 3–7×. It has also been
  observed *not* to clamp inside its window, so agents must measure rather than assume, and any
  latency number should carry the `power.limit` it was measured at.

## 7. Loose ends

- Everything is **uncommitted** on `collab`. Nothing has been pushed.
- tmux sessions `collab-agent-0` / `collab-agent-1` hold pilot scrollback; three Docker containers
  sit in `Created` state. Harmless, tidy when convenient.
- `plan/HOST-mithril.md` is stale and unused by this launcher.
- `bench/` and `paper_convergence/` are untracked and unrelated to this work.
