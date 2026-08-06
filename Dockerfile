FROM ubuntu:24.04

ARG USERNAME=ubuntu
ARG USER_UID=1000
ARG USER_GID=1000
ARG GPU_ARCH=blackwell
ARG CUDA_VERSION=cu130

# System packages
RUN apt update && apt upgrade -y && apt dist-upgrade -y \
 && apt install -y --no-install-recommends \
      ca-certificates curl less git procps sudo unzip gnupg2 gh jq \
      cmake g++ make ripgrep fd-find python3.12-dev ninja-build python-is-python3 \
      tinyproxy \
 && curl -4fsSL --retry 100 --retry-all-errors --retry-delay 3 --retry-max-time 600 https://deb.nodesource.com/setup_24.x | bash - \
 && apt install -y nodejs \
 && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
 && apt autoremove && apt clean

# CUDA 13.0 toolkit (nvcc + headers) so agents can JIT-compile custom torch
# C++/CUDA extensions (e.g. a DA-Transformer DAG best-alignment kernel) via
# torch.utils.cpp_extension. The torch cu130 wheel ships only the CUDA
# runtime, not the compiler; without nvcc/CUDA_HOME those builds fail. Matches
# the wheel's CUDA 13.0. (~4-6 GB.)
RUN curl -4fsSL --retry 100 --retry-all-errors --retry-delay 3 --retry-max-time 600 \
      -o /tmp/cuda-keyring.deb \
      https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb \
 && dpkg -i /tmp/cuda-keyring.deb && rm /tmp/cuda-keyring.deb \
 && apt update && apt install -y --no-install-recommends cuda-toolkit-13-0 \
 && ln -sf /usr/local/cuda-13.0 /usr/local/cuda \
 && apt clean && rm -rf /var/lib/apt/lists/*

# Rename the built-in `ubuntu` user to ${USERNAME} and align UID/GID with host
RUN if [ "${USERNAME}" != "ubuntu" ]; then \
      groupmod -n ${USERNAME} ubuntu \
      && usermod -l ${USERNAME} -d /home/${USERNAME} -m ubuntu; \
    fi \
 && if [ "${USER_GID}" != "$(id -g ${USERNAME})" ]; then groupmod -g ${USER_GID} ${USERNAME}; fi \
 && if [ "${USER_UID}" != "$(id -u ${USERNAME})" ]; then usermod -u ${USER_UID} ${USERNAME}; fi \
 && echo "${USERNAME} ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/${USERNAME} \
 && chmod 0440 /etc/sudoers.d/${USERNAME} \
 && mkdir -p /workspace /home/${USERNAME}/.pi/agent \
 && chown -R ${USER_UID}:${USER_GID} /workspace /home/${USERNAME}

WORKDIR /workspace
USER ${USER_UID}:${USER_GID}
ENV HOME=/home/${USERNAME}
ENV SHELL=/bin/bash
ENV PATH="/home/${USERNAME}/.npm-global/bin:/home/${USERNAME}/.local/bin:$PATH"
# CUDA toolkit on PATH so nvcc + torch.utils.cpp_extension find the compiler.
ENV CUDA_HOME=/usr/local/cuda
ENV PATH="$CUDA_HOME/bin:$PATH"
ENV LD_LIBRARY_PATH="$CUDA_HOME/lib64"

# Git
RUN git config --global user.email "${USERNAME}@localhost" \
 && git config --global user.name "${USERNAME}"

# uv (the Claude Code CLI is intentionally NOT installed — the bench is pi-only
# for reproducibility).
RUN curl -4LsSf --retry 100 --retry-all-errors --retry-delay 2 --retry-max-time 600 https://astral.sh/uv/install.sh | sh

# Python environment — uv init in one layer, deps in the next so changing a
# dep version doesn't invalidate the project scaffold. `--no-package`: plain
# app layout (pyproject + main.py + .python-version + .gitignore, no src/).
# Without it, uv 0.12 `uv init` scaffolds a *packaged* project named after
# the workdir ("workspace") at src/workspace/__init__.py + a uv_build
# [build-system]; that gets committed and then collides with the agent's own
# src/ layout (code ends up nested under src/workspace/). `--bare` would go
# too far — it also drops .python-version/.gitignore, breaking the git add
# below and un-ignoring .venv.
RUN uv init --no-package --python 3.12 \
 && sed -i 's/requires-python.*/requires-python = "==3.12.*"/' pyproject.toml \
 && printf '\n[tool.uv]\nindex-strategy = "unsafe-best-match"\n\n[[tool.uv.index]]\nname = "pytorch"\nurl = "https://download.pytorch.org/whl/%s"\n\n[tool.uv.sources]\ntorch = { index = "pytorch" }\n' "${CUDA_VERSION}" >> pyproject.toml

# Pin every direct dep to a known-good version. Bump explicitly when needed
# (see versions on pypi.org/pypi/<name>/json — `info.version` is latest).
RUN uv add \
      'torch==2.12.0' \
      'datasets==4.8.5' \
      'sacrebleu==2.6.0' \
      'sentencepiece==0.2.1' \
      'tensorboard==2.20.0' \
      'tbparse==0.0.9'
# NB: no unbabel-comet / CometKiwi here — the bench forbids pretrained models
# (incl. as a data-selection filter), and offline runtime can't fetch it anyway.
# COMET as a scoring metric lives in the external scorer, not the agent image.

# Bench data: WMT14 EN-DE train + dev (newstest2013) baked at /opt/mtbench,
# OUTSIDE the runtime bind-mounts (/workspace and /home come from STATE_DIR at
# run time and shadow image content, so data there would vanish). Test
# (newstest2014) is deliberately NOT materialized — the agent must never reach
# it; the external scorer holds it. Downloaded online here at build; the raw HF
# cache (which does contain the test split) is then purged so only the
# train+validation arrow survives in /opt. Runtime is offline (ENV below, set
# AFTER this layer so the build-time download still works).
USER root
RUN mkdir -p /opt/mtbench && chown ${USER_UID}:${USER_GID} /opt/mtbench
USER ${USER_UID}:${USER_GID}
# Pin the HF cache to a build-only path so the purge is deterministic (default
# would be $HOME/.cache, under /home, which gets seeded to STATE_DIR). Then ASSERT
# test-exclusion (audit MED): the saved dataset has exactly train+validation, and
# no test-named file survives anywhere the agent can reach (/opt image + /home seed).
RUN HF_HOME=/tmp/hfbuild HF_DATASETS_CACHE=/tmp/hfbuild/ds /workspace/.venv/bin/python -c "\
from datasets import load_dataset, DatasetDict; \
ds = load_dataset('wmt/wmt14', 'de-en'); \
keep = DatasetDict({'train': ds['train'], 'validation': ds['validation']}); \
keep.save_to_disk('/opt/mtbench/wmt14'); \
print('mtbench data rows:', {k: keep[k].num_rows for k in keep})" \
 && rm -rf /tmp/hfbuild /home/${USERNAME}/.cache/huggingface \
 && /workspace/.venv/bin/python -c "\
from datasets import load_from_disk; \
d = load_from_disk('/opt/mtbench/wmt14'); \
assert set(d.keys()) == {'train', 'validation'}, ('unexpected splits', d.keys()); \
print('assert OK: baked splits', sorted(d.keys()))" \
 && if find /home /opt -iname '*newstest2014*' -print 2>/dev/null | grep -q .; then \
      echo 'FATAL: newstest2014 (test) data present in image — build aborted' >&2; exit 1; \
    else echo 'assert OK: no test-named files under /home or /opt'; fi

# Offline runtime: no internet except the agent's own inference endpoint
# (enforced host-side by run.sh's egress lock). Point the HF libraries at the
# local baked dataset only and never phone home. HF_TOKEN is deliberately never
# set — no gated/pretrained downloads. MTBENCH_DATA is where the agent reads
# the corpus (datasets.load_from_disk), splits: train + validation(dev); no test.
ENV HF_DATASETS_OFFLINE=1
ENV TRANSFORMERS_OFFLINE=1
ENV HF_HUB_OFFLINE=1
ENV MTBENCH_DATA=/opt/mtbench/wmt14

# Initialize workspace repo. Append project-specific ignores (checkpoints,
# logs, tensorboard event files) to the .gitignore that uv init created,
# so the agent's per-version commits don't store large binary artifacts.
# Without this, .git/ mirrors every saved ckpt and bloats the workspace.
# Keep README.md — pyproject's `readme = "README.md"` points at it, and uv
# metadata reads (uv build / some tooling) error if it's missing.
RUN rm -f main.py \
 && printf '\n# Training artifacts — do not commit\nckpt/\nlog/\ntb/\nruns/\n*.pt\n*.safetensors\n' >> .gitignore \
 && git branch -M main \
 && git add * .python-version .gitignore \
 && git commit -m init

# pi-coding-agent (the only agent — no Claude Code, no caveman skill, for
# reproducibility). nvm provides node for the npm-global pi install.
RUN curl -4 --retry 100 --retry-all-errors --retry-delay 3 --retry-max-time 600 -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash \
 && npm config set prefix '~/.npm-global' \
 && npm install -g @earendil-works/pi-coding-agent@0.82.1

# Tools
RUN mkdir -p tools \
 && git clone https://github.com/clab/fast_align.git tools/fast_align \
 && mkdir -p tools/fast_align/build \
 && cd tools/fast_align/build && cmake .. && make -j$(nproc)
ENV PATH="$PATH:/workspace/tools/fast_align/build"

# Put the project venv first on PATH so bare `python`/`pip` resolve to the
# torch-equipped interpreter. The container ships no unversioned `python`
# (only `uv` + `/usr/bin/python3` without deps), so agents that reflexively
# call `python foo.py` otherwise hit "command not found" or a torch-less
# python3. `/workspace/.venv` is built here and bind-mounted at runtime.
ENV PATH="/workspace/.venv/bin:$PATH"

# Project structure + pi extension. plan/PLAN.md is dropped into doc/ by
# `make seed` rather than baked in, so it lives in $STATE_DIR alongside the
# rest of the working tree.
RUN mkdir -p src doc d ckpt log
COPY --chown=${USER_UID}:${USER_GID} models.json /home/${USERNAME}/.pi/agent/models.json
# Pi compaction/retry profiles. entrypoint.sh installs the right one at
# container start based on PI_MODEL; the default seeds the image so
# claude/non-pi runs still get a valid settings.json.
COPY --chown=${USER_UID}:${USER_GID} pi-settings /etc/pi-settings
RUN install -m 0644 /etc/pi-settings/settings.default.json \
                    /home/${USERNAME}/.pi/agent/settings.json
# Pre-trust the workspace so pi 0.82+ doesn't block first startup on its
# interactive trust prompt (agent runs headless). trust-manager keys on the
# canonical cwd; the container always runs pi with cwd=/workspace.
RUN printf '{\n  "/workspace": true\n}\n' > /home/${USERNAME}/.pi/agent/trust.json
COPY --chown=${USER_UID}:${USER_GID} pi-extensions /tmp/pi-extensions
RUN pi install /tmp/pi-extensions/azure-anthropic \
 && pi install /tmp/pi-extensions/azure-openai \
 && pi install /tmp/pi-extensions/gemini \
 && pi install /tmp/pi-extensions/checkpoint \
 && pi install /tmp/pi-extensions/resources

# Entrypoint wrapper (pi settings-profile selection + `exec "$@"`). The bench
# runs on-demand with no preemption, so no spot-interruption watcher/hook.
# Also bake the egress-proxy config + entrypoint: the SAME image runs a second
# container in proxy mode (ops/bench-egress.sh) as the agent's only route out.
USER root
COPY ops/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY ops/proxy/proxy-entrypoint.sh /usr/local/bin/proxy-entrypoint.sh
COPY ops/proxy/tinyproxy.conf /etc/tinyproxy/tinyproxy.conf
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/proxy-entrypoint.sh
USER ${USER_UID}:${USER_GID}
