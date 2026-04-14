FROM ubuntu:24.04

ARG USERNAME
ARG USER_UID
ARG USER_GID
ARG GPU_ARCH=ampere
ARG CUDA_VERSION=cu126

# System packages
RUN apt update && apt upgrade -y && apt dist-upgrade -y \
 && apt install -y --no-install-recommends \
      ca-certificates curl less git procps sudo unzip gnupg2 gh jq \
 && curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
 && apt install -y nodejs \
 && apt autoremove && apt clean

# CUDA toolkit (needed to build flash-attn from source on Ampere)
RUN if [ "${GPU_ARCH}" = "ampere" ]; then \
      curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb \
        -o /tmp/cuda-keyring.deb \
      && dpkg -i /tmp/cuda-keyring.deb && rm /tmp/cuda-keyring.deb \
      && apt update \
      && apt install -y --no-install-recommends cuda-nvcc-12-6 cuda-cudart-dev-12-6 \
      && apt clean; \
    fi
ENV CUDA_HOME=/usr/local/cuda

# User setup — skip if UID/GID already exist in the image
RUN getent group ${USER_GID} >/dev/null \
      || /usr/sbin/addgroup --gid ${USER_GID} ${USERNAME} \
 && getent passwd ${USER_UID} >/dev/null \
      || /usr/sbin/adduser --uid ${USER_UID} \
           --ingroup $(getent group ${USER_GID} | cut -d: -f1) \
           --disabled-password --gecos "" ${USERNAME} \
 && USR=$(getent passwd ${USER_UID} | cut -d: -f1) \
 && echo "${USR} ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/${USR} \
 && chmod 0440 /etc/sudoers.d/${USR} \
 && mkdir -p /workspace /home/${USERNAME}/.claude \
 && chown -R ${USER_UID}:${USER_GID} /workspace /home/${USERNAME}

WORKDIR /workspace
USER ${USER_UID}:${USER_GID}
ENV SHELL=/bin/bash
ENV HOME=/home/${USERNAME}
ENV PATH="$PATH:/home/${USERNAME}/.local/bin"

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

# Claude plugins
RUN claude plugin marketplace add JuliusBrussee/caveman \
 && claude plugin install caveman@caveman

# Project structure
RUN mkdir src doc d ckpt log
COPY PLAN.md /workspace/doc/PLAN.md
