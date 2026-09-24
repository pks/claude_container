#!/bin/bash
set -euo pipefail

USERNAME="${USERNAME:-ubuntu}"
CONTAINER_HOME="/home/$USERNAME"
STATE_DIR="${STATE_DIR:-$PWD/state}"

# Pre-load defaults from $STATE_DIR/.config (written by run.sh on first
# fresh start, see bottom of this file). Lets `make run` reuse the
# original profile/model/thinking/gpu on resume without re-specifying
# them. Explicit positional args and env vars still win.
CONFIG_PROFILE= CONFIG_GPU= CONFIG_THINKING= CONFIG_MODEL=
if [ -f "$STATE_DIR/.config" ]; then
  while IFS='=' read -r k v; do
    case "$k" in
      profile)  CONFIG_PROFILE="$v" ;;
      gpu)      CONFIG_GPU="$v" ;;
      thinking) CONFIG_THINKING="$v" ;;
      model)    CONFIG_MODEL="$v" ;;
    esac
  done < "$STATE_DIR/.config"
fi

PROFILE="${1:-${PROFILE:-${CONFIG_PROFILE:-pi-azure}}}"
GPU="${2:-${GPU:-${CONFIG_GPU:-all}}}"
# Reasoning effort. Empty here triggers per-profile defaults below. Override
# with e.g. THINKING=high make run PROFILE=pi-azure.
THINKING="${THINKING:-${CONFIG_THINKING:-}}"

# Per-profile model default sourced from .config only when the resolved
# profile matches the recorded one — model strings are profile-specific.
PI_MODEL_DEFAULT=
if [ -n "$CONFIG_PROFILE" ] && [ "$CONFIG_PROFILE" = "$PROFILE" ]; then
  PI_MODEL_DEFAULT="$CONFIG_MODEL"
fi

# Parse the env file into the host shell (for script-side dispatch like pi-azure
# key selection) and collect the names so we can forward them to the
# container below. Sourced with `.` it would execute as shell code under
# `set -eu` — risky for a secrets file and brittle around values with
# command substitutions or unescaped metacharacters. Each line is treated
# as a literal KEY=VALUE; one surrounding pair of matching quotes is
# stripped, otherwise values are passed through verbatim.
#
# ENV_FILE points at one of the repo's per-vendor secret files, e.g.
#   ENV_FILE=../.env-openrouter ./run.sh pi-or
# The repo root keeps .env-{claude,deepseek,gemini,gpt,openrouter} (all matched by
# the root .gitignore's `.env-*`); the default stays ./.env so existing use is
# unchanged. A missing file is an error when named explicitly — silently running
# keyless would fail later with a confusing provider error.
ENV_FILE="${ENV_FILE:-.env}"
if [ -n "${ENV_FILE:-}" ] && [ "$ENV_FILE" != .env ] && [ ! -f "$ENV_FILE" ]; then
  echo "run.sh: ENV_FILE '$ENV_FILE' not found (cwd $(pwd))" >&2
  exit 1
fi
ENV_NAMES_FROM_FILE=()
if [ -f "$ENV_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    name="${BASH_REMATCH[2]}"
    val="${BASH_REMATCH[3]}"
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    export "$name=$val"
    ENV_NAMES_FROM_FILE+=("$name")
  done < "$ENV_FILE"
  echo "run.sh: loaded $(printf '%s ' "${ENV_NAMES_FROM_FILE[@]}")from $ENV_FILE" >&2
fi

# --gpus alone is not enough: the nvidia runtime hook injects the GPU
# behind Docker's back, so Docker/systemd never record the device nodes.
# With cgroup v2 + the systemd cgroup driver, any `systemctl daemon-reload`
# (apt upgrades, unit edits, ...) rebuilds the container's device cgroup
# from what Docker recorded — and the GPU vanishes from the running
# container ("Failed to initialize NVML: Unknown Error"). Passing the
# nodes explicitly with --device registers them with Docker so reloads
# re-apply them. See "Containers losing access to GPUs" in
# https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/troubleshooting.html
GPU_FLAG=()
add_dev() { if [ -e "$1" ]; then GPU_FLAG+=(--device "$1"); fi; }
for d in /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools \
         /dev/nvidia-modeset /dev/nvidia-nvswitchctl /dev/nvidia-caps/*; do
  add_dev "$d"
done
case "$GPU" in
  all)
    GPU_FLAG+=(--gpus all)
    for d in /dev/nvidia[0-9]*; do add_dev "$d"; done
    ;;
  *)
    GPU_FLAG+=(--gpus "device=$GPU")
    if [[ "$GPU" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
      IFS=',' read -ra GPU_IDS <<< "$GPU"
      for id in "${GPU_IDS[@]}"; do add_dev "/dev/nvidia$id"; done
    else
      # UUID or other selector — no direct /dev node mapping; pass all
      # nodes (cgroup access only; visibility still set by --gpus).
      for d in /dev/nvidia[0-9]*; do add_dev "$d"; done
    fi
    ;;
esac

# /workspace and $CONTAINER_HOME bind-mount from $STATE_DIR so code, ckpts,
# sessions, plugins, npm-global, etc. survive container exits and restarts.
# `make seed` populates $STATE_DIR from the image. STATE_DIR itself is set
# at the top of this script so .config can feed defaults.
IMAGE="${IMAGE:-mtbench-container}"
if [ ! -d "$STATE_DIR/workspace" ] || [ ! -d "$STATE_DIR/home" ]; then
  echo "run.sh: $STATE_DIR is not seeded — run 'make seed' first" >&2
  exit 1
fi

MOUNTS=(
  -v "$STATE_DIR/workspace:/workspace"
  -v "$STATE_DIR/home:$CONTAINER_HOME"
)

# The bench arm is pi-only for reproducibility; the collab arm also runs Claude Code
# (PROFILE=claude) on the host's subscription. Providers are configured per profile below.
ENVS=()

# Claude Code auth: COPY the host credential into this agent's own state home instead
# of bind-mounting the host file. Several agents run concurrently per host
# (ops/collab-launch.sh) and Claude Code rewrites .credentials.json on token refresh,
# so a shared mount is a write race on the file every agent depends on. $STATE_DIR/home
# is already per-agent, so a copy gives each agent a private, refreshable credential.
# Copied only when absent: an in-container refresh must not be clobbered on restart.
#
# ~/.claude.json is deliberately NOT copied. It is user state (tips, project history),
# not auth, and the in-container Claude Code replaces a foreign copy with a fresh
# config anyway — dropping hasCompletedOnboarding, which leaves the agent parked on
# the interactive theme picker forever (a headless run never answers it). Write a
# minimal onboarding-complete config instead; CLAUDE_CODE_THEME alone does not skip it.
if [ "$PROFILE" = claude ]; then
  mkdir -p "$STATE_DIR/home/.claude"
  if [ -f ~/.claude/.credentials.json ] && [ ! -f "$STATE_DIR/home/.claude/.credentials.json" ]; then
    install -m 600 ~/.claude/.credentials.json "$STATE_DIR/home/.claude/.credentials.json"
    echo "run.sh: seeded .credentials.json into $STATE_DIR/home" >&2
  fi
  if [ ! -f "$STATE_DIR/home/.claude/.credentials.json" ]; then
    echo "run.sh: no ~/.claude/.credentials.json on this host — run 'claude' once to log in" >&2
    exit 1
  fi
  # Merge the first-run flags in (create the file if absent, preserve whatever Claude
  # Code has already written). Idempotent across restarts. THREE interactive gates block
  # a headless agent and no env var skips them in 2.1.x — each one parks the agent on a
  # menu it can never answer, burning the whole wall clock:
  #   1. theme picker              -> hasCompletedOnboarding
  #   2. "is this folder trusted?" -> projects./workspace.hasTrustDialogAccepted
  #                                   (the Claude Code analogue of ~/.pi/agent/trust.json)
  #   3. --dangerously-skip-permissions acceptance -> bypassPermissionsModeAccepted
  # Key names came from a working host config and from the CLI bundle's own strings
  # (grep -aoE 'bypassPermissions[A-Za-z]*'); re-check them after a Claude Code upgrade.
  CFG="$STATE_DIR/home/.claude.json" python3 - <<'PY'
import copy, json, os
p = os.environ["CFG"]
try:
    with open(p) as f:
        cfg = json.load(f)
except Exception:
    cfg = {}
before = copy.deepcopy(cfg)
cfg.setdefault("installMethod", "native")
cfg.setdefault("autoUpdates", False)
cfg["hasCompletedOnboarding"] = True
cfg["bypassPermissionsModeAccepted"] = True
cfg["theme"] = cfg.get("theme", "dark")
proj = cfg.setdefault("projects", {}).setdefault("/workspace", {})
proj["hasTrustDialogAccepted"] = True
proj.setdefault("allowedTools", [])
proj.setdefault("hasClaudeMdExternalIncludesApproved", False)
proj.setdefault("hasClaudeMdExternalIncludesWarningShown", False)
if cfg != before:
    with open(p, "w") as f:
        json.dump(cfg, f, indent=2)
    print(f"run.sh: pre-accepted onboarding + /workspace trust in {p}", flush=True)
PY
  ENVS+=(
    -e CLAUDE_CODE_THEME=dark
    -e CLAUDE_CODE_ACCEPT_TOS=yes
    -e CLAUDE_CODE_SKIP_TRUST_SCREEN=1
  )
  # Adaptive thinking overrides --effort; keep it off unless ADAPTIVE_THINKING is set.
  [ -z "${ADAPTIVE_THINKING:-}" ] && ENVS+=(-e CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING=yes)
fi
# Forward every variable declared in .env into the container — adding one
# there auto-propagates without script changes. Names came from the safe
# parser above; `-e VAR` (no value) tells docker to pull from our env.
if [ "${#ENV_NAMES_FROM_FILE[@]}" -gt 0 ]; then
  for name in "${ENV_NAMES_FROM_FILE[@]}"; do
    ENVS+=(-e "$name")
  done
fi

# Bench egress lock: forward proxy vars so the agent's outbound HTTP(S) routes
# through the allowlist proxy (set by ops/bench-egress.sh). On the --internal
# bench network the proxy is the only route out, so this fails closed — a client
# that ignores the proxy reaches nothing rather than leaking. No-op off the bench.
for pv in HTTPS_PROXY HTTP_PROXY NO_PROXY https_proxy http_proxy no_proxy; do
  [ -n "${!pv:-}" ] && ENVS+=(-e "$pv=${!pv}")
done
# Node 24's global fetch/undici only honors the proxy env when NODE_USE_ENV_PROXY
# is set — without it pi ignores HTTPS_PROXY, and on the --internal bench net that
# means it reaches nothing and hangs. Set it whenever a proxy is configured.
[ -n "${HTTPS_PROXY:-}${https_proxy:-}" ] && ENVS+=(-e NODE_USE_ENV_PROXY=1)

# Card name (e.g. TITAN, A6000) — the plan tells the agent to check $MTBENCH_GPU, and it
# must be there in both arms, so it is forwarded independently of the collab block below.
[ -n "${MTBENCH_GPU:-}" ] && ENVS+=(-e "MTBENCH_GPU=$MTBENCH_GPU")

# Mithril spot signal — the in-container watcher polls it and SIGINTs the agent on
# preemption. Self-disabling: on any other host /opt/mithril does not exist, nothing is
# mounted and the watcher never starts. See "Preemption handling" in the README.
[ -d /opt/mithril ] \
  && MOUNTS+=(-v /opt/mithril:/opt/mithril:ro)

# Collaboration (ops/collab-launch.sh): if COLLAB_HOST_DIR is set, mount the agent's
# shared-blackboard clone at /collab and forward its identity so collab-{post,say,view}
# work inside the container. No-op otherwise (solo arm / non-collab runs).
if [ -n "${COLLAB_HOST_DIR:-}" ]; then
  MOUNTS+=(-v "$COLLAB_HOST_DIR:/collab")
  ENVS+=(-e "COLLAB_DIR=${COLLAB_DIR:-/collab}")
  for cv in COLLAB_AGENT COLLAB_GPU; do
    [ -n "${!cv:-}" ] && ENVS+=(-e "$cv=${!cv}")
  done
fi

# Session location (for resume detection) + fresh-start prompt. Caveman is dropped
# for reproducibility — the agent gets a neutral instruction, no skill. Claude Code
# keeps its sessions elsewhere, hence the per-profile path.
case "$PROFILE" in
  claude) SESSION_DIR=.claude/projects ;;
  *)      SESSION_DIR=.pi/agent/sessions ;;
esac
FRESH_PROMPT='carry out doc/PLAN.md'
RESUME_PROMPT='Your prior session was interrupted (a manual exit or restart) and is now being resumed. /workspace and your prior session are bind-mounted from host-persistent storage, so they survived intact. Read /workspace/STATUS.md if present, check `git log` and the working-tree state, then continue carrying out doc/PLAN.md from where you left off.'

RESUMING=0
[ -n "$SESSION_DIR" ] \
  && [ -n "$(find "$STATE_DIR/home/$SESSION_DIR" -name '*.jsonl' -print -quit 2>/dev/null)" ] \
  && RESUMING=1

if [ "$RESUMING" = 1 ]; then
  echo "run.sh: resuming $PROFILE in $STATE_DIR (make reseed to start fresh)" >&2
  PI_RESUME=(-c)
  CLAUDE_RESUME=(--continue)
  EFFECTIVE_PROMPT="$RESUME_PROMPT"
else
  echo "run.sh: starting fresh $PROFILE in $STATE_DIR" >&2
  PI_RESUME=()
  CLAUDE_RESUME=()
  EFFECTIVE_PROMPT="$FRESH_PROMPT"
fi

case "$PROFILE" in
  claude)
    # Claude Code on the host subscription — no API key, so no per-token cost.
    # Permission bypass comes from settings.json (permissions.defaultMode), NOT from
    # --dangerously-skip-permissions: that flag opens an interactive "accept
    # responsibility" dialog which a headless agent cannot answer, and which
    # bypassPermissionsModeAccepted in .claude.json does not suppress in 2.1.x.
    ENTRYPOINT=claude
    MODEL="${MODEL:-claude-opus-5}"
    EFFECTIVE_THINKING="${THINKING:-max}"
    ARGS=("${CLAUDE_RESUME[@]}" --model "$MODEL" \
          --effort "$EFFECTIVE_THINKING" "$EFFECTIVE_PROMPT")
    ;;
  pi-ollama)
    ENTRYPOINT="$CONTAINER_HOME/.npm-global/bin/pi"
    MODEL=qwen3.6:35b
    EFFECTIVE_THINKING="${THINKING:-xhigh}"
    ARGS=("${PI_RESUME[@]}" --provider ollama --model "$MODEL" --thinking "$EFFECTIVE_THINKING" "$EFFECTIVE_PROMPT")
    ;;
  pi-azure)
    ENTRYPOINT="$CONTAINER_HOME/.npm-global/bin/pi"
    : "${AZURE_BASE_URL:?AZURE_BASE_URL must be set for pi-azure}"
    # Forward explicitly: the .env passthrough above only catches vars
    # listed in .env, but users may export these in their shell instead.
    ENVS+=(-e AZURE_BASE_URL)
    if [ -n "${ANTHROPIC_API_KEY:-}" ] && [ -n "${OPENAI_API_KEY:-}" ]; then
      echo "pi-azure: set only one of ANTHROPIC_API_KEY or OPENAI_API_KEY" >&2
      exit 1
    elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
      ENVS+=(-e ANTHROPIC_API_KEY)
      PI_MODEL="${PI_MODEL:-${PI_MODEL_DEFAULT:-claude-opus-5}}"
      ENVS+=(-e "PI_MODEL=$PI_MODEL")
      MODEL="$PI_MODEL"
      EFFECTIVE_THINKING="${THINKING:-max}"
      ARGS=("${PI_RESUME[@]}" --provider anthropic --model "$MODEL" --thinking "$EFFECTIVE_THINKING" "$EFFECTIVE_PROMPT")
    elif [ -n "${OPENAI_API_KEY:-}" ]; then
      ENVS+=(-e OPENAI_API_KEY)
      PI_MODEL="${PI_MODEL:-${PI_MODEL_DEFAULT:-gpt-5.6-sol}}"
      ENVS+=(-e "PI_MODEL=$PI_MODEL")
      # DeepSeek-V4-Pro on Azure caps reasoning_effort at "high" — to get
      # "max" effort you select a different model variant (PI_MODEL=
      # DeepSeek-V4-Pro-Max), not a higher reasoning_effort value.
      # Other Azure OpenAI deployments (gpt-5.x) accept xhigh in practice
      # despite Azure docs listing xhigh only for gpt-5.1-codex-max.
      case "$PI_MODEL" in
        DeepSeek-*|deepseek-*) THINKING_DEFAULT=high ;;
        *)                     THINKING_DEFAULT=xhigh ;;
      esac
      MODEL="$PI_MODEL"
      EFFECTIVE_THINKING="${THINKING:-$THINKING_DEFAULT}"
      ARGS=("${PI_RESUME[@]}" --provider openai --model "$MODEL" --thinking "$EFFECTIVE_THINKING" "$EFFECTIVE_PROMPT")
    else
      echo "pi-azure: set ANTHROPIC_API_KEY or OPENAI_API_KEY" >&2
      exit 1
    fi
    ;;
  pi-or)
    ENTRYPOINT="$CONTAINER_HOME/.npm-global/bin/pi"
    : "${OPENROUTER_API_KEY:?OPENROUTER_API_KEY must be set for pi-or (try ENV_FILE=../.env-openrouter)}"
    # Forward explicitly so the key also works when exported in the shell rather
    # than listed in ENV_FILE. NOTE: pi takes it on argv too, so the key is visible
    # in `ps` on the host and inside the container.
    ENVS+=(-e OPENROUTER_API_KEY)
    # Model is a full OpenRouter id and must resolve in the live catalog — a stale
    # default 404s on the first turn. The previous default (moonshotai/kimi-k2.6) no
    # longer appears in /api/v1/models; verified present 2026-09-09: z-ai/glm-5.3,
    # deepseek/deepseek-v4-pro-0813, google/gemini-3.8-flash, qwen/qwen3.8-max-0902.
    PI_MODEL="${PI_MODEL:-${PI_MODEL_DEFAULT:-z-ai/glm-5.3}}"
    ENVS+=(-e "PI_MODEL=$PI_MODEL")
    MODEL="$PI_MODEL"
    EFFECTIVE_THINKING="${THINKING:-high}"
    ARGS=("${PI_RESUME[@]}" --provider openrouter --api-key "$OPENROUTER_API_KEY" --model "$MODEL" --thinking "$EFFECTIVE_THINKING" "$EFFECTIVE_PROMPT")
    ;;
  pi-gemini)
    ENTRYPOINT="$CONTAINER_HOME/.npm-global/bin/pi"
    : "${GEMINI_API_KEY:?GEMINI_API_KEY must be set for pi-gemini}"
    ENVS+=(-e GEMINI_API_KEY)
    PI_MODEL="${PI_MODEL:-${PI_MODEL_DEFAULT:-gemini-3.1-pro-preview}}"
    ENVS+=(-e "PI_MODEL=$PI_MODEL")
    MODEL="$PI_MODEL"
    EFFECTIVE_THINKING="${THINKING:-high}"
    ARGS=("${PI_RESUME[@]}" --provider gemini --model "$MODEL" --thinking "$EFFECTIVE_THINKING" "$EFFECTIVE_PROMPT")
    ;;
  bash)
    ENTRYPOINT=bash
    MODEL=
    EFFECTIVE_THINKING=
    ARGS=()
    ;;
  *)
    echo "usage: $0 {claude|pi-azure|pi-ollama|pi-gemini|pi-or|bash} [gpu-id|all]" >&2
    exit 1
    ;;
esac

# On first fresh start, write a meta-tracking config to $STATE_DIR/.config
# documenting which harness / model / effort this state-dir was launched
# with. Skipped on resumes and for the bash debug profile. Persists across
# resumes; delete the file to regenerate on the next fresh start.
if [ "$RESUMING" = 0 ] && [ "$PROFILE" != bash ] && [ ! -f "$STATE_DIR/.config" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
  CC_COMMIT="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  PI_VERSION="$(grep -oE '@(earendil-works|mariozechner)/pi-coding-agent@[0-9.]+' "$SCRIPT_DIR/Dockerfile" 2>/dev/null | head -1 | sed 's|.*@||')"
  PLAN_PATH="$STATE_DIR/workspace/doc/PLAN.md"
  if [ -f "$PLAN_PATH" ]; then
    # PLAN.md first line follows `# PLAN <YYYYMMDD>` by convention; strip
    # the leading `# ` so the recorded version is just `PLAN <YYYYMMDD>`.
    PLAN_VERSION="$(head -n1 "$PLAN_PATH" | sed 's/^#[[:space:]]*//')"
    PLAN_MD5="$(md5sum "$PLAN_PATH" | awk '{print $1}')"
  else
    PLAN_VERSION=unknown
    PLAN_MD5=unknown
  fi
  cat > "$STATE_DIR/.config" <<EOF
# claude_container startup config — written once on first fresh start.
# Delete this file to regenerate on the next fresh start; resumes never
# overwrite it. Mid-run harness upgrades are NOT reflected here; record
# those in the attempt MD instead.

written_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
hostname=$(hostname 2>/dev/null || echo unknown)
state_dir=$STATE_DIR
profile=$PROFILE
model=$MODEL
thinking=$EFFECTIVE_THINKING
gpu=$GPU
image=$IMAGE
claude_container_commit=$CC_COMMIT
pi_version=${PI_VERSION:-unknown}
plan_version=$PLAN_VERSION
plan_md5=$PLAN_MD5
EOF
  echo "run.sh: wrote $STATE_DIR/.config" >&2
fi

exec docker run \
  -it \
  --rm \
  "${GPU_FLAG[@]}" \
  --shm-size="${SHM_SIZE:-8g}" \
  --network "${DOCKER_NETWORK:-host}" \
  -u "$(id -u):$(id -g)" \
  -w /workspace \
  --entrypoint /usr/local/bin/entrypoint.sh \
  "${MOUNTS[@]}" \
  "${ENVS[@]}" \
  "$IMAGE" \
  "$ENTRYPOINT" "${ARGS[@]}"
