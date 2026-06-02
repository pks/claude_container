# Claude Container

Containerized harness for autonomously running a machine translation experiments under an LLM coding agent — Claude Code or [pi-coding-agent](https://github.com/earendil-works/pi-mono).

The agent is dropped into `/workspace` inside the container and told to carry out
[`plan/PLAN.md`](plan/PLAN.md), which defines the research task (match Transformer-base
quality with a pure diffusion model), the data/eval setup, and the iteration protocol.

## Layout

- `Dockerfile` — Ubuntu 24.04 + Node 24, CUDA toolkit (Ampere/Blackwell), `uv` Python 3.12
  env with torch / lightning / datasets / sacrebleu / transformers / flash-attn,
  Claude Code, pi-coding-agent, the `caveman` skill, and `fast_align`.
- `Makefile` — `make image` detects the local GPU arch (`ampere` → `cu126`,
  `blackwell` → `cu130`) and builds the `claude-container` image; `make seed`
  populates a host-persistent state directory from the image.
- `run.sh` — launches the container under one of several agent profiles
  (see below). Auto-detects whether to resume an existing session or start fresh.
- `ops/` — `entrypoint.sh` (started inside the container), `mithril-watch.sh`
  (Mithril spot-preemption watcher), `mithril-hook.sh` (Claude Code PreToolUse
  hook that nudges the agent to checkpoint when preemption is signaled), and
  `claude-settings.json` registering the hook. `ops/mithril-host/` holds the
  host-side systemd kit (`home-ubuntu-exp.mount`, `diffusemt-resume.service`,
  `resume.sh`, `install.sh`) that auto-mounts the labelled `exp` volume and
  re-launches the agent in a detached tmux session on every boot — used on
  Mithril spot nodes so a relocation comes back up unattended.
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
  - `mithril` — pi-side spot-preemption nudge (Claude Code gets it via the
    PreToolUse hook in `ops/`).
  - `checkpoint` — periodic (~30 min, `CHECKPOINT_INTERVAL_MS` to override)
    nudge to refresh `/workspace/STATUS.md` and commit, with an embedded
    GPU/disk snapshot.
  - `resources` — registers a `resources` tool the agent can call on demand
    for an `nvidia-smi` + `df -h /workspace` snapshot.
- `plan/PLAN.md` — the task description handed to the agent. Required for
  `make seed`. `plan/` is gitignored, so a clean clone won't have it — create
  one before seeding. `plan/PLAN-D3PM.md` and `plan/NOTES.md` are auxiliary
  planning notes.

## Quick start

End-to-end on a fresh host (from inside this repo):

```sh
# one-time per host
make image                                # build the image (auto-detects GPU arch)

# per attempt
cp plan/PLAN-v3.md plan/PLAN.md           # whichever PLAN to ship to the agent
cp plan/HOST-titan.md plan/HOST.md        # or HOST-mithril.md, or skip
cat > .env <<'EOF'
AZURE_BASE_URL=https://...
OPENAI_API_KEY=...
EOF
make seed                                 # populate $STATE_DIR/{workspace,home}

# first launch (settings persist into $STATE_DIR/.config)
PROFILE=pi-azure THINKING=max GPU=0 make run

# any later restart of this state-dir
make run                                  # PROFILE/GPU/THINKING/PI_MODEL filled from .config

# optional: Mithril spot auto-resume on this node
sudo bash ops/mithril-host/install.sh --start
```

For parallel runs on the same host (e.g. titan2 cards 0 and 1), give each
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

`plan/HOST.md` (optional) is copied to `workspace/doc/HOST.md` if present. The
PLAN tells the agent to read it for per-machine specifics. Templates in the meta
repo:

- `plan/HOST-titan.md` — cron-managed power cap schedule for titan / titan2
- `plan/HOST-mithril.md` — Mithril spot-preemption behavior and state-survival contract

Copy or symlink the right one into `plan/HOST.md` before `make seed`
(`plan/HOST.md` is gitignored so per-host choices don't leak into the plan repo):

```sh
cp HOST-mithril.md plan/HOST.md   # on a Mithril spot instance
cp HOST-titan.md   plan/HOST.md   # on titan / titan2
```

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
| `claude`    | Claude Code, `claude-opus-4-8`, `--effort max`                   |
| `pi-ollama` | pi against a local Ollama (`qwen3.6:35b`)                        |
| `pi-azure`  | pi against Azure; set `AZURE_BASE_URL` and one of `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`. Override the model with `PI_MODEL=...` (e.g. `PI_MODEL=DeepSeek-V4-Pro` for DeepSeek on Azure AI Foundry) |
| `pi-gemini` | pi against Google's OpenAI-compatible Gemini endpoint (`gemini-3.1-pro-preview` by default; override with `PI_MODEL=...`). Needs `GEMINI_API_KEY`. Implicit prompt caching only — no `cache_control` markers via the compat layer. Set `PI_GEMINI_DEBUG=1` for request/response logging to `/workspace/log/gemini-debug.log`. |
| `pi-or`     | pi against OpenRouter (`moonshotai/kimi-k2.6`); needs `OPENROUTER_API_KEY` |
| `bash`      | Drop into a shell in the container                               |

`run.sh` checks for an existing session under the profile's session directory
inside `$STATE_DIR/home/`. If found, it resumes via `--continue` / `-c` with a
resume prompt; otherwise it starts fresh with
`/skill:caveman lite\ncarry out doc/PLAN.md` (`pi-or` runs the full caveman
skill instead of caveman lite).

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
hostname=titan2
state_dir=/home/ubuntu/exp/diffusemt/state
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

### Spot / preemption handling

When the host has `/opt/mithril/` (Mithril spot nodes), `run.sh` mounts it
read-only into the container; `entrypoint.sh` then backgrounds
`mithril-watch.sh`, which polls the Mithril signal file and SIGINTs the agent
on preemption. The Claude Code PreToolUse hook (`ops/mithril-hook.sh`) injects
a nudge to commit, write `/workspace/STATUS.md`, ack via
`touch /workspace/.shutdown-acked`, and exit. On non-Mithril hosts
`/opt/mithril/` doesn't exist, so the watcher never starts and the hook
short-circuits — everything else works the same.

### Mithril spot auto-resume (systemd)

Mithril spot nodes can be relocated to a fresh VM at any time. The kit in
`ops/mithril-host/` makes the new VM mount the persistent volume and re-launch
the agent in a detached tmux session on boot, so a relocation comes back up
unattended. Bootstrap on a fresh node:

```sh
# 1. Format & label the persistent volume (one-time; xfs labelled `exp`).
sudo mkfs.xfs -L exp /dev/sdX
sudo mkdir -p /home/ubuntu/exp && sudo chown ubuntu:ubuntu /home/ubuntu/exp

# 2. Clone claude_container into /home/ubuntu/exp/diffusemt/ (the path the
#    systemd unit expects); seed state and build the image once.
git clone <this repo> /home/ubuntu/exp/diffusemt
cd /home/ubuntu/exp/diffusemt
make image && make seed   # see "Setup" above

# 3. (Optional) pin per-host overrides; without this, run.sh reads them from
#    $STATE_DIR/.config on resume (see "Config persistence").
cat > /home/ubuntu/exp/.diffusemt-resume.env <<EOF
PROFILE=pi-azure
GPU=all
# THINKING=max
EOF

# 4. Install the systemd units (registers but doesn't start; pass --start to
#    activate immediately on a fresh node).
sudo bash ops/mithril-host/install.sh [--start]
```

Prerequisites (NVIDIA runtime, docker, tmux, ubuntu user, no fstab entry
racing the mount unit) and operational hints (`tmux attach -t diffusemt`,
manual start/stop) are documented in the header of `ops/mithril-host/install.sh`.
Safe to run on a live node with an agent already running — the units are
enabled, not started, so the next preemption-recovery boot is the first time
systemd takes over.

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
