FROM ubuntu:24.04

ARG USERNAME
ARG USER_UID
ARG USER_GID
ARG CUDA_VERSION=cu126

# System packages
RUN apt update && apt upgrade -y && apt dist-upgrade -y \
 && apt install -y --no-install-recommends \
      ca-certificates curl less git procps sudo unzip gnupg2 gh jq \
 && curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
 && apt install -y nodejs \
 && apt autoremove && apt clean

# User setup
RUN /usr/sbin/addgroup --gid ${USER_GID} ${USERNAME} \
 && /usr/sbin/adduser --uid ${USER_UID} --ingroup ${USERNAME} --disabled-password --gecos "" ${USERNAME} \
 && echo "${USERNAME} ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/${USERNAME} \
 && chmod 0440 /etc/sudoers.d/${USERNAME} \
 && mkdir -p /workspace /home/${USERNAME}/.claude \
 && chown -R ${USERNAME}:${USERNAME} /workspace /home/${USERNAME}/.claude

WORKDIR /workspace
USER ${USERNAME}
ENV SHELL=/bin/bash
ENV PATH="$PATH:/home/${USERNAME}/.local/bin"

# Git
RUN git config --global user.email "${USERNAME}@localhost" \
 && git config --global user.name "${USERNAME}"

# Claude Code + uv
RUN curl -fsSL https://claude.ai/install.sh | bash \
 && curl -LsSf https://astral.sh/uv/install.sh | sh

# Python environment
RUN uv init \
 && printf '\n[[tool.uv.index]]\nname = "pytorch"\nurl = "https://download.pytorch.org/whl/%s"\n\n[tool.uv.sources]\ntorch = { index = "pytorch" }\n' "${CUDA_VERSION}" >> pyproject.toml \
 && uv add torch lightning datasets sacrebleu sentencepiece tensorboard tbparse \
 && if echo "${CUDA_VERSION}" | grep -q '^cu13'; then uv add 'flash-attn-4[cu13]'; fi

# Initialize workspace repo
RUN rm -f README.md main.py \
 && git branch -M main \
 && git add * .python-version .gitignore \
 && git commit -m init

# Claude plugins
RUN claude plugin marketplace add JuliusBrussee/caveman \
 && claude plugin install caveman@caveman

# Project structure
RUN mkdir src doc d ckpt log
COPY PLAN.md /workspace/doc/PLAN.md
