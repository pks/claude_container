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
 && mkdir -p /workspace /home/${USERNAME}/.claude /home/${USERNAME}/.pi/agent \
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

# Claude Code + uv
RUN curl -4fsSL --retry 100 --retry-all-errors --retry-delay 3 --retry-max-time 600 https://claude.ai/install.sh | bash \
 && curl -4LsSf --retry 100 --retry-all-errors --retry-delay 2 --retry-max-time 600 https://astral.sh/uv/install.sh | sh

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
      'tbparse==0.0.9' \
      'unbabel-comet==2.2.7'


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

# Claude plugins + pi-coding-agent + caveman skill. Plugin enable state is
# declared in ops/claude-settings.json (copied near the end of this file) —
# install fetches the plugin code, settings.json wires up the enable.
RUN claude plugin marketplace add JuliusBrussee/caveman \
 && claude plugin install caveman@caveman \
 && curl -4 --retry 100 --retry-all-errors --retry-delay 3 --retry-max-time 600 -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash \
 && npm config set prefix '~/.npm-global' \
 && npm install -g @earendil-works/pi-coding-agent@0.82.1 \
 && npx skills add JuliusBrussee/caveman --yes

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
 && pi install /tmp/pi-extensions/mithril \
 && pi install /tmp/pi-extensions/checkpoint \
 && pi install /tmp/pi-extensions/resources

# Mithril spot-interruption handling: entrypoint wrapper, signal-file
# watcher, and Claude Code PreToolUse hook. Data persistence is handled
# host-side via bind mounts in run.sh, not by this image.
USER root
COPY ops/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY ops/mithril-watch.sh /usr/local/bin/mithril-watch.sh
COPY ops/mithril-hook.sh /usr/local/bin/mithril-hook.sh
COPY ops/mithril-nudge.txt /usr/local/share/mithril-nudge.txt
RUN chmod 0755 /usr/local/bin/entrypoint.sh \
               /usr/local/bin/mithril-watch.sh \
               /usr/local/bin/mithril-hook.sh \
 && chmod 0644 /usr/local/share/mithril-nudge.txt
USER ${USER_UID}:${USER_GID}
COPY --chown=${USER_UID}:${USER_GID} ops/claude-settings.json /home/${USERNAME}/.claude/settings.json
