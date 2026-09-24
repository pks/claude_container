# Claude Container

Containerized harness for running long-horizon ML experiments under an LLM coding agent —
Claude Code or [pi-coding-agent](https://github.com/earendil-works/pi-mono). It supplies the
container, GPU wiring, durable state, preemption handling, egress control and a compute-time
budget. The task is staged in from outside, so nothing here is tied to a particular
experiment.

The agent is dropped into `/workspace` inside the container and told to carry out
`plan/PLAN.md` — the research task, the data/eval setup and the iteration protocol. That
file is staged in before a run and is **not** part of this repo (see `plan/` under Layout),
which is what keeps the harness task-agnostic.

## Layout

- `Dockerfile` — Ubuntu 24.04 + Node 24, CUDA toolkit (Ampere/Blackwell), `uv` Python 3.12
  env with torch / lightning / datasets / sacrebleu / transformers / flash-attn,
  Claude Code, pi-coding-agent, the `caveman` skill, and `fast_align`.
- `Makefile` — `make image` detects the local GPU arch (`ampere` → `cu126`,
  `blackwell` → `cu130`) and builds the `claude-container` image; `make seed`
  populates a host-persistent state directory from the image.
- `run.sh` — launches the container under one of several agent profiles
  (see below). Auto-detects whether to resume an existing session or start fresh.
- `ops/` — `entrypoint.sh` (started inside the container), `bench-egress.sh`
  (egress lock + compute-time budget), `bench-cost.py` (sums a run's token
  spend from the persisted pi session), `proxy/` (the allowlist proxy sidecar)
  and `collab/` + `collab-launch.sh` (multi-agent launcher: one agent per GPU,
  each with its own state dir and tmux session, optionally sharing a git
  blackboard mounted at `/collab`).
  `ops/host-resume/` holds the host-side systemd kit (`bench-resume.service`,
  `bench-resume.sh`, `install.sh`, `uninstall.sh`) that remounts durable state
  and re-launches the agent on every boot, so a preemptible host comes back up
  unattended. `ops/mithril-*` and `ops/mithril-host/` are an optional fast path
  for providers that signal preemption in advance — inert unless `/opt/mithril`
  is present; see "Preemption handling".
- `models.json` — pi-coding-agent model registry, copied to `~/.pi/agent/models.json`.
- `pi-settings/` — pi-coding-agent settings profiles (retry + compaction).
  `entrypoint.sh` picks `settings.gpt.json` when `PI_MODEL=gpt-*` (compacts
  under GPT-5.5's 272K input-pricing cliff) and `settings.default.json`
  otherwise (compacts at ~80% of 1M context). Both files share the same
  retry budget, tuned to match `pi-extensions/*/retry-fetch.ts`.
- `pi-extensions/` — local pi extensions installed into the image at build time:
  - `azure-anthropic`, `azure-openai` — Azure provider URL/header setup,
    plus a shared fetch retry wrapper (`_shared/retry-fetch.ts`) and an
    `openai-responses` error-message shim that triggers pi's built-in retry.
  - `checkpoint` — periodic (~30 min, `CHECKPOINT_INTERVAL_MS` to override)
    nudge to refresh `/workspace/STATUS.md` and commit, with an embedded
    GPU/disk snapshot.
  - `resources` — registers a `resources` tool the agent can call on demand
    for an `nvidia-smi` + `df -h /workspace` snapshot.
- `plan/` — **staging only, and gitignored: no plan content lives in this repo.**
  `make seed` reads `plan/PLAN.md` (the task handed to the agent) and, if present,
  `plan/HOST.md` (that host's GPU notes, staged to `doc/HOST.md`). Both are
  assembled or copied in before seeding, and a clean clone has neither. Sources:
  a plan directory kept outside this repo (`PLAN-*.md`, `HOST-<host>.md`), or
  `ops/collab-launch.sh`, which assembles `plan/PLAN.md` at launch.
  The files that launcher assembles — a task doc (`TASK_DOC`) plus an optional
  overlay appended for the sharing arm (`OVERLAY_DOC`) — are **not** here either:
  they define an experiment. `COLLAB_DIR` points at the directory holding them
  and defaults to a sibling checkout.
- `docs/` — prose documentation, including a `HANDOFF.md` when a run is in
  flight. Anything describing *what is being studied* belongs outside this repo.

## Quick start

End-to-end on a fresh host (from inside this repo):

```sh
# one-time per host
make image                                # build the image (auto-detects GPU arch)

# per attempt — stage the plan in ($PLAN_SRC = wherever the plan dir lives)
mkdir -p plan
cp "$PLAN_SRC/PLAN-<version>.md" plan/PLAN.md   # the task to ship to the agent
cp "$PLAN_SRC/HOST-<host>.md"    plan/HOST.md   # per-machine notes, or skip
cat > .env <<'EOF'
AZURE_BASE_URL=https://...
OPENAI_API_KEY=...
EOF
make seed                                 # populate $STATE_DIR/{workspace,home}

# first launch (settings persist into $STATE_DIR/.config)
PROFILE=pi-azure THINKING=max GPU=0 make run

# any later restart of this state-dir
make run                                  # PROFILE/GPU/THINKING/PI_MODEL filled from .config

# optional: auto-resume on this node after a reboot/preemption
sudo bash ops/host-resume/install.sh --start
```

For parallel runs on one host (e.g. cards 0 and 1), give each
its own `STATE_DIR` and `GPU=`:

```sh
STATE_DIR=$PWD/state-card0 GPU=0 PROFILE=pi-azure THINKING=max make seed run
STATE_DIR=$PWD/state-card1 GPU=1 PROFILE=pi-azure THINKING=max make seed run
```

Detailed semantics in the sections below.

## Setup

```sh
make image                  # build the image (auto-detects GPU arch)
# ...create plan/PLAN.md describing the task for the agent...
# ...optional: drop plan/HOST.md with per-machine notes (power caps, quirks)...
make seed                   # populate ./state/{workspace,home} from the image
```

`make seed` is one-time. After image rebuilds that touch the user home dir
(installed tools, agent configs, etc.), `make reseed` wipes `$STATE_DIR`
and re-runs the seed.

`plan/HOST.md` (optional) is copied to `workspace/doc/HOST.md` if present, and the
PLAN tells the agent to read it for per-machine specifics — the kind of thing an
agent cannot discover but must plan around: a power cap on a schedule, an
unsupported dtype, spot-preemption behaviour and what survives it.

Keep one `HOST-<host>.md` per machine, each describing only that machine, in the
same external plan directory as the PLAN files. One card per doc: an agent told
about two GPUs when it has one will plan for the wrong throughput.

```sh
mkdir -p plan
cp "$PLAN_SRC/HOST-$(hostname -s).md" plan/HOST.md
```

Staging in rather than checking the plan directory out here is deliberate: it keeps
this repo task-agnostic, and per-host choices out of the plan directory's history.

## Run

```sh
./run.sh <profile> [gpu-id|all]
# or
PROFILE=<profile> GPU=<gpu-id|all> make run
```

Bare `make run` (no args) reads back the original launch settings from
`$STATE_DIR/.config` — see "Config persistence" below. Useful for systemd
auto-resume and one-line restarts.

Profiles:

| Profile     | Agent / provider                                                 |
|-------------|------------------------------------------------------------------|
| `claude`    | Claude Code, `claude-opus-4-8` (override with `MODEL=...`, e.g. `MODEL=claude-fable-5`), `--effort max` (override with `THINKING=...`). Adaptive thinking is disabled by default; set `ADAPTIVE_THINKING=on` to leave it on (recommended for Fable 5 / Opus 4.8 where the model picks effort dynamically). |
| `pi-ollama` | pi against a local Ollama (`qwen3.6:35b`)                        |
| `pi-azure`  | pi against Azure; set `AZURE_BASE_URL` and one of `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`. Override the model with `PI_MODEL=...` (e.g. `PI_MODEL=DeepSeek-V4-Pro` for DeepSeek on Azure AI Foundry) |
| `pi-gemini` | pi against Google's OpenAI-compatible Gemini endpoint (`gemini-3.1-pro-preview` by default; override with `PI_MODEL=...`). Needs `GEMINI_API_KEY`. Implicit prompt caching only — no `cache_control` markers via the compat layer. Set `PI_GEMINI_DEBUG=1` for request/response logging to `/workspace/log/gemini-debug.log`. |
| `pi-or`     | pi against OpenRouter (`moonshotai/kimi-k2.6`); needs `OPENROUTER_API_KEY` |
| `bash`      | Drop into a shell in the container                               |

`run.sh` checks for an existing session under the profile's session directory
inside `$STATE_DIR/home/`. If found, it resumes via `--continue` / `-c` with a
resume prompt; otherwise it starts fresh with
`/skill:caveman\ncarry out doc/PLAN.md` — the full caveman skill on every profile
(Claude Code uses `/caveman`).

Host `~/.claude/.credentials.json` and `~/.claude.json` are mounted in if
present so the `claude` profile reuses host auth.

### Environment

Provider credentials and other secrets are read from the host environment.
You can either export them in your shell, or put them in a gitignored `.env`
file in the repo root — `run.sh` parses `.env` literally (no shell evaluation;
values with `&`, `?`, `$(...)`, etc. pass through verbatim) and forwards every
declared variable into the container.

```ini
# .env
AZURE_BASE_URL=https://...
ANTHROPIC_API_KEY=sk-...
```

For `pi-azure` set exactly one of `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`; the
script picks the corresponding pi provider. `AZURE_BASE_URL` and the chosen
key are forwarded into the container explicitly even if they live only in the
host shell.

### State persistence

`make seed` populates `$STATE_DIR` (default `./state/`) from the image:

- `state/workspace/` → bind-mounted to `/workspace` in the container
  (code, checkpoints, logs, the agent's `STATUS.md`).
- `state/home/` → bind-mounted to `/home/ubuntu` in the container
  (agent sessions under `.pi/agent/sessions` and `.claude/projects`,
  plugins, npm globals, shell history).

Container exits don't lose work; the next `./run.sh` resumes against the same
workspace and session.

### Config persistence

On the first fresh start of a state-dir (no prior session found), `run.sh`
writes `$STATE_DIR/.config` recording how this run was launched:

```ini
written_at=2026-06-02T11:30:00Z
hostname=gpu-host-1
state_dir=/home/ubuntu/exp/run/state
profile=pi-azure
model=gpt-5.5
thinking=xhigh
gpu=2
image=claude-container
claude_container_commit=dcc611d
pi_version=0.77.0
plan_version=PLAN 20260526
plan_md5=b1267256a4dbbcf0acd98b921bb753ae
```

The file is written once and never overwritten on resume — delete it to
regenerate on the next fresh start. Mid-run harness upgrades (image rebuilds,
pi version bumps) are *not* reflected here; record those in your run-tracking
notes instead.

On every subsequent invocation, `run.sh` reads `.config` and uses it as the
default for `PROFILE` / `GPU` / `THINKING` / `PI_MODEL`. So once a state-dir
has been launched with a specific recipe, bare `make run` (or
`./run.sh "" ""`) is enough to resume it — no need to remember the original
flags. Explicit env vars or positional args still override.

### Preemption handling

Handled generically, so it works on any preemptible host:

- **The agent banks its own state.** The `checkpoint` pi extension nudges it
  every ~30 min to refresh `/workspace/STATUS.md` and commit, so whatever is on
  the durable volume at reclaim time is a usable resume point.
- **The clock measures active time.** `ops/bench-egress.sh` counts compute, not
  wall clock, so downtime is free and a reclaim does not eat the budget.
- **The host comes back by itself.** `ops/host-resume/` re-launches the agent on
  boot (below).

On top of that there is an **optional Mithril-specific fast path**, for providers
that publish an advance preemption signal. It is **inert unless `/opt/mithril`
exists**, which is every other host:

- `run.sh` bind-mounts `/opt/mithril` read-only when the directory is present.
- `ops/entrypoint.sh` then backgrounds `ops/mithril-watch.sh`, which polls the
  signal file and SIGINTs the agent on preemption.
- `ops/mithril-hook.sh` (a Claude Code `PreToolUse` hook, registered in
  `ops/claude-settings.json`) and the `mithril` pi extension nudge the agent to
  commit, write `STATUS.md`, ack via `touch /workspace/.shutdown-acked`, and exit.
  Both exit immediately when the signal file is absent.
- `ops/mithril-host/` is the older host-side systemd kit for that provider,
  superseded by the generic `ops/host-resume/` below; kept for reference.

### Auto-resume after a preemption reboot (systemd)

`ops/host-resume/` makes a rebooted node wait for its durable volume, then
re-launch the agent in a detached tmux session, so a reclaim recovers
unattended. Bootstrap on a fresh node:

```sh
# 1. Clone this repo and build once; $REPO and $STATE_DIR are yours to choose.
git clone <this repo> /home/ubuntu/mtbench
cd /home/ubuntu/mtbench
make image && make seed   # see "Setup" above

# 2. Set host specifics. STATE_DIR must live on a volume that survives
#    preemption -- it holds the workspace, checkpoints, the compute clock
#    (.bench_elapsed_s) and the completion marker (.bench_done).
sudo cp ops/host-resume/mtbench-resume.env.example /etc/mtbench-resume.env
sudo "$EDITOR" /etc/mtbench-resume.env     # REPO, STATE_DIR, MOUNT, IMAGE,
                                           # PROFILE, GPU, INFERENCE_ALLOWLIST

# 3. Install the unit (registers but doesn't start; --start activates now).
sudo bash ops/host-resume/install.sh [--start]
```

Prerequisites (docker + NVIDIA runtime + tmux, an `ubuntu` user) are in the
header of `ops/host-resume/install.sh`. Safe on a live node with an agent
already running — the unit is enabled, not started, so the next recovery boot
is the first time systemd takes over.

The unit deliberately declares **no** mount dependency and no `WorkingDirectory=`:
systemd would auto-inject a hard `RequiresMountsFor=`, and a volume that times
out on a fresh boot would then mark this `Type=oneshot` unit "dependency failed"
with no restart — a bug that stranded pilot nodes for hours. `bench-resume.sh`
waits for the volume and docker in-script instead, so a late attach is recovered
rather than fatal.

### Username

The image is built with `USERNAME=ubuntu` and the host UID/GID by default (see
`Makefile`). To override, set `USERNAME` on both the image build and the run:

```sh
make USERNAME=alice image seed
USERNAME=alice make run
# or: USERNAME=alice ./run.sh <profile>
```

`run.sh` and the Makefile derive all `/home/$USERNAME/...` paths from the var,
so no in-script edits are needed.

## Future work

### Alternative harnesses to evaluate

- https://github.com/Endi1/fabrica
- https://github.com/aattaran/deepclaude
- https://github.com/dirac-run/dirac
- https://github.com/antoinezambelli/forge

### Models to wire up

Already integrated (✓) or pending (○):

- ✓ GPT-5.5 / Codex (via `pi-azure`, `PI_MODEL=gpt-5.5`)
- ✓ DeepSeek V4 (via `pi-azure`, `PI_MODEL=DeepSeek-V4-Pro`)
- ✓ Gemini 3.1 Pro Preview (via `pi-gemini`)
- ○ Gemini 3.5 — https://blog.google/innovation-and-ai/models-and-research/gemini-models/gemini-3-5/#gemini-3-5-flash
- ○ Qwen 3.7 — https://qwen.ai/blog?id=qwen3.7
- ○ Kimi K2.6 (currently wired through `pi-or`)
- ○ GLM 5.1
- ○ granite4.1 — https://ollama.com/library/granite4.1
- ○ Mistral Medium 3.5 / vibe remote agents — https://mistral.ai/news/vibe-remote-agents-mistral-medium-3-5

### Reading / listening

- https://share.transistor.fm/s/451da102

## Source

Dockerfile derived from
https://github.com/anthropics/claude-code/blob/main/.devcontainer/Dockerfile.
