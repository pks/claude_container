# Claude Container

Containerized harness for autonomously running a machine translation experiments under an LLM coding agent — Claude Code or [pi-coding-agent](https://github.com/mariozechner/pi-coding-agent).

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
  `claude-settings.json` registering the hook.
- `models.json` — pi-coding-agent model registry, copied to `~/.pi/agent/models.json`.
- `pi-extensions/` — local pi providers for Azure (`azure-anthropic`, `azure-openai`),
  installed into the image at build time.
- `plan/PLAN.md` — the task description handed to the agent. Required for
  `make seed`. `plan/` is gitignored, so a clean clone won't have it — create
  one before seeding. `plan/PLAN-D3PM.md` and `plan/NOTES.md` are auxiliary
  planning notes.

## Setup

```sh
make image                  # build the image (auto-detects GPU arch)
# ...create plan/PLAN.md describing the task for the agent...
make seed                   # populate ./state/{workspace,home} from the image
```

`make seed` is one-time. After image rebuilds that touch `/home/ubuntu`
(installed tools, agent configs, etc.), `make reseed` wipes `$STATE_DIR`
and re-runs the seed.

## Run

```sh
./run.sh <profile> [gpu-id|all]
```

Profiles:

| Profile     | Agent / provider                                                 |
|-------------|------------------------------------------------------------------|
| `claude`    | Claude Code, `claude-opus-4-6`, `--effort max`                   |
| `pi-ollama` | pi against a local Ollama (`qwen3.6:35b`)                        |
| `pi-azure`  | pi against Azure; set `AZURE_BASE_URL` and one of `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` |
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

### Spot / preemption handling

When the host has `/opt/mithril/` (Mithril spot nodes), `run.sh` mounts it
read-only into the container; `entrypoint.sh` then backgrounds
`mithril-watch.sh`, which polls the Mithril signal file and SIGINTs the agent
on preemption. The Claude Code PreToolUse hook (`ops/mithril-hook.sh`) injects
a nudge to commit, write `/workspace/STATUS.md`, ack via
`touch /workspace/.shutdown-acked`, and exit. On non-Mithril hosts
`/opt/mithril/` doesn't exist, so the watcher never starts and the hook
short-circuits — everything else works the same.

### Username

The image is built with `USERNAME=ubuntu` and the host UID/GID (see `Makefile`),
and `run.sh` hardcodes `/home/ubuntu/...` paths for the pi entrypoint. If you
rebuild with a different `USERNAME`, update those paths in `run.sh` to match.

## Source

Dockerfile derived from
https://github.com/anthropics/claude-code/blob/main/.devcontainer/Dockerfile.
