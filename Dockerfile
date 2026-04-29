FROM ubuntu:24.04

ARG USERNAME=ubuntu
ARG USER_UID=1000
ARG USER_GID=1000
ARG GPU_ARCH=ampere
ARG CUDA_VERSION=cu126

# System packages
RUN apt update && apt upgrade -y && apt dist-upgrade -y \
 && apt install -y --no-install-recommends \
      ca-certificates curl less git procps sudo unzip gnupg2 gh jq \
      cmake g++ make \
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

# Python environment
RUN uv init --python 3.12 \
 && sed -i 's/requires-python.*/requires-python = "==3.12.*"/' pyproject.toml \
 && printf '\n[[tool.uv.index]]\nname = "pytorch"\nurl = "https://download.pytorch.org/whl/%s"\n\n[tool.uv.sources]\ntorch = { index = "pytorch" }\n' "${CUDA_VERSION}" >> pyproject.toml \
 && uv add torch lightning datasets sacrebleu sentencepiece tensorboard tbparse \
 && case "${GPU_ARCH}" in \
      ampere)    uv pip install packaging wheel psutil && uv pip install flash-attn --no-build-isolation;; \
      blackwell) uv pip install 'flash-attn-4[cu13]' --prerelease=allow;; \
    esac

# Initialize workspace repo
RUN rm -f README.md main.py \
 && git branch -M main \
 && git add * .python-version .gitignore \
 && git commit -m init

# Claude plugins + pi-coding-agent + caveman skill
RUN claude plugin marketplace add JuliusBrussee/caveman \
 && claude plugin install caveman@caveman \
 && curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash \
 && npm config set prefix '~/.npm-global' \
 && npm install -g @mariozechner/pi-coding-agent \
 && npx skills add JuliusBrussee/caveman --yes

# Project structure + pi extension
RUN mkdir src doc d ckpt log
COPY --chown=${USER_UID}:${USER_GID} plan/PLAN.md /workspace/doc/PLAN.md
COPY --chown=${USER_UID}:${USER_GID} models.json /home/${USERNAME}/.pi/agent/models.json
COPY --chown=${USER_UID}:${USER_GID} pi-extensions /tmp/pi-extensions
RUN pi install /tmp/pi-extensions/azure-anthropic \
 && pi install /tmp/pi-extensions/azure-openai
