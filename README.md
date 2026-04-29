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
  `blackwell` → `cu130`) and builds the `claude-container` image.
- `run.sh` — launches the container under one of several agent profiles
  (see below).
- `models.json` — pi-coding-agent model registry, copied to `~/.pi/agent/models.json`.
- `pi-extensions/` — local pi providers for Azure (`azure-anthropic`, `azure-openai`),
  installed into the image at build time.
- `plan/PLAN.md` — the task description handed to the agent. `plan/PLAN-D3PM.md`
  and `plan/NOTES.md` are auxiliary planning notes.

## Build

```sh
make image
```

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

The default prompt is `/skill:caveman lite\ncarry out doc/PLAN.md`. Host
`~/.claude/.credentials.json` and `~/.claude.json` are mounted in if present so
the `claude` profile reuses host auth.

### Environment

Provider credentials and other secrets are read from the current shell, so source
the gitignored `env` file before running a `pi-*` profile:

```sh
source env
./run.sh pi-azure 0
```

`env` typically exports `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `AZURE_BASE_URL`,
and/or `OPENROUTER_API_KEY` — whichever the chosen profile needs.

### Username

The image is built with `USERNAME=ubuntu` and the host UID/GID (see `Makefile`),
and `run.sh` hardcodes `/home/ubuntu/...` paths for the pi entrypoint. If you
rebuild with a different `USERNAME`, update those paths in `run.sh` to match.

## Source

Dockerfile derived from
https://github.com/anthropics/claude-code/blob/main/.devcontainer/Dockerfile.
