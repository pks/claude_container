FROM ubuntu:24.04

RUN apt update && apt install -y --no-install-recommends \
  ca-certificates \
  curl \
  less \
  git \
  procps \
  sudo \
  fzf \
  zsh \
  man-db \
  unzip \
  gnupg2 \
  gh \
  jq \
  nano \
  vim \
  wget \
  htop \
  && apt autoremove && apt clean

RUN /usr/sbin/addgroup --gid 1337 pks && \
    /usr/sbin/adduser --uid 1337 --ingroup pks --disabled-password --gecos "" pks

RUN mkdir -p /workspace /home/pks/.claude && \
  chown -R pks:pks /workspace /home/pks/.claude

ARG GIT_DELTA_VERSION=0.19.2
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && \
  apt install -y nodejs

RUN echo "pks ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/pks && \
    chmod 0440 /etc/sudoers.d/pks

WORKDIR /workspace
USER pks
RUN git config --global user.email "pks@localhost" && git config --global user.name "pks"
ENV SHELL=/bin/zsh
ENV EDITOR=vim
ENV VISUAL=vim
RUN curl -fsSL https://claude.ai/install.sh | bash
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="$PATH:/home/pks/.local/bin"
WORKDIR /workspace
RUN uv init && uv add torch --index-url https://download.pytorch.org/whl/cu126 && uv add lightning datasets sacrebleu sentencepiece tensorboard tbparse
RUN rm -f README.md main.py && git branch -M main && git add * .python-version .gitignore && git commit -m init
RUN claude plugin marketplace add JuliusBrussee/caveman && claude plugin install caveman@caveman
RUN mkdir src doc d ckpt log
COPY PLAN.md /workspace/doc/PLAN.md
