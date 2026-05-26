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
      cmake g++ make ripgrep fd-find \
 && curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
 && apt install -y nodejs \
 && apt autoremove && apt clean

# CUDA toolkit (needed to build flash-attn from source on Ampere)
RUN if [ "${GPU_ARCH}" = "ampere" ]; then \
      curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb \
        -o /tmp/cuda-keyring.deb \
      && dpkg -i /tmp/cuda-keyring.deb && rm /tmp/cuda-keyring.deb \
      && apt update \
      && apt install -y --no-install-recommends cuda-nvcc-12-6 cuda-cudart-dev-12-6 python3.12-dev \
      && apt clean; \
    fi
ENV CUDA_HOME=/usr/local/cuda

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

# Git
RUN git config --global user.email "${USERNAME}@localhost" \
 && git config --global user.name "${USERNAME}"

# Claude Code + uv
RUN curl -fsSL https://claude.ai/install.sh | bash \
 && curl -LsSf https://astral.sh/uv/install.sh | sh

# Python environment — split into three RUN layers so the slow flash-attn
# install (especially the ampere source build) is cached independently of
# the cheaper torch/datasets layer above it. Tweaking dataset deps no longer
# invalidates flash-attn.
RUN uv init --python 3.12 \
 && sed -i 's/requires-python.*/requires-python = "==3.12.*"/' pyproject.toml \
 && printf '\n[[tool.uv.index]]\nname = "pytorch"\nurl = "https://download.pytorch.org/whl/%s"\n\n[tool.uv.sources]\ntorch = { index = "pytorch" }\n\n[tool.uv.exclude-newer-package]\ndatasets = "1 day"\nsacrebleu = "1 day"\nsentencepiece = "1 day"\ntensorboard = "1 day"\ntbparse = "1 day"\n' "${CUDA_VERSION}" >> pyproject.toml

RUN uv add torch datasets sacrebleu sentencepiece tensorboard tbparse

# flash-attn: separate layer. Ampere builds from source (~minutes); pinning
# this as its own step means it's only re-run when GPU_ARCH or torch changes.
RUN case "${GPU_ARCH}" in \
      ampere)    uv pip install packaging wheel psutil \
                 && uv pip install flash-attn --no-build-isolation;; \
      blackwell) uv pip install 'flash-attn-4[cu13]' --prerelease=allow;; \
    esac

# Initialize workspace repo. Append project-specific ignores (checkpoints,
# logs, tensorboard event files) to the .gitignore that uv init created,
# so the agent's per-version commits don't store large binary artifacts.
# Without this, .git/ mirrors every saved ckpt and bloats the workspace.
RUN rm -f README.md main.py \
 && printf '\n# Training artifacts — do not commit\nckpt/\nlog/\ntb/\nruns/\n*.pt\n*.safetensors\n' >> .gitignore \
 && git branch -M main \
 && git add * .python-version .gitignore \
 && git commit -m init

# Claude plugins + pi-coding-agent + caveman skill
RUN claude plugin marketplace add JuliusBrussee/caveman \
 && claude plugin install caveman@caveman \
 && curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash \
 && npm config set prefix '~/.npm-global' \
 && npm install -g @earendil-works/pi-coding-agent@0.75.5 \
 && npx skills add JuliusBrussee/caveman --yes

# Patch pi to accept --thinking max for Opus 4.7. See ops/pi-patch-max-effort.sh
# for rationale (Opus 4.7 supports effort=max via Anthropic API; pi's built-in
# definitions and validation list cap at xhigh — outdated).
COPY ops/pi-patch-max-effort.sh /tmp/pi-patch-max-effort.sh
RUN bash /tmp/pi-patch-max-effort.sh && rm /tmp/pi-patch-max-effort.sh

# Tools
RUN mkdir tools \
 && git clone https://github.com/clab/fast_align.git tools/fast_align \
 && mkdir tools/fast_align/build \
 && cd tools/fast_align/build && cmake .. && make -j$(nproc)
ENV PATH="$PATH:/workspace/tools/fast_align/build"

# Project structure + pi extension. plan/PLAN.md is dropped into doc/ by
# `make seed` rather than baked in, so it lives in $STATE_DIR alongside the
# rest of the working tree.
RUN mkdir src doc d ckpt log
COPY --chown=${USER_UID}:${USER_GID} models.json /home/${USERNAME}/.pi/agent/models.json
# Pi compaction/retry profiles. entrypoint.sh installs the right one at
# container start based on PI_MODEL; the default seeds the image so
# claude/non-pi runs still get a valid settings.json.
COPY --chown=${USER_UID}:${USER_GID} pi-settings /etc/pi-settings
RUN install -m 0644 /etc/pi-settings/settings.default.json \
                    /home/${USERNAME}/.pi/agent/settings.json
COPY --chown=${USER_UID}:${USER_GID} pi-extensions /tmp/pi-extensions
RUN pi install /tmp/pi-extensions/azure-anthropic \
 && pi install /tmp/pi-extensions/azure-openai \
 && pi install /tmp/pi-extensions/gemini \
 && pi install /tmp/pi-extensions/mithril \
 && pi install /tmp/pi-extensions/checkpoint \
 && pi install /tmp/pi-extensions/resources \
 && pi install npm:pi-web-access

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
