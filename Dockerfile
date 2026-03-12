FROM ubuntu:24.04

ARG TZ
ENV TZ="$TZ"

ARG CLAUDE_CODE_VERSION=latest

# Install basic development tools and iptables/ipset
RUN apt-get update && apt-get install -y --no-install-recommends \
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
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  jq \
  nano \
  vim \
  wget \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN /usr/sbin/addgroup --gid 1337 pks && \
    /usr/sbin/adduser --uid 1337 --ingroup pks --disabled-password --gecos "" pks

# Ensure default pks user has access to /usr/local/share
RUN mkdir -p /usr/local/share/npm-global && \
  chown -R pks:pks /usr/local/share

ARG USERNAME=pks

# Persist bash history.
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  && mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R $USERNAME /commandhistory

# Set `DEVCONTAINER` environment variable to help with orientation
ENV DEVCONTAINER=true

# Create workspace and config directories and set permissions
RUN mkdir -p /workspace /home/pks/.claude && \
  chown -R pks:pks /workspace /home/pks/.claude

WORKDIR /workspace

ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  sudo dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

RUN curl -fsSL https://deb.nodesource.com/setup_22.x | sudo bash -
RUN sudo apt-get install -y nodejs

RUN echo "pks ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/pks && \
    chmod 0440 /etc/sudoers.d/pks

# Set up non-root user
USER pks

# Install global packages
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

# Set the default shell to zsh rather than sh
ENV SHELL=/bin/zsh

# Set the default editor and visual
ENV EDITOR=vim
ENV VISUAL=vim

# Default powerline10k theme
ARG ZSH_IN_DOCKER_VERSION=1.2.0
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
  -p git \
  -p fzf \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \
  -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  -x

# Install Claude
#RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash && \
#    nvm install 24 && \
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Install uv
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

ENV PATH="$PATH:/home/pks/.local/bin"

# Copy and set up firewall script, setup sudo
#COPY init-firewall.sh /usr/local/bin/
#USER root
#RUN chmod +x /usr/local/bin/init-firewall.sh && \
#  echo "pks ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/pks && \
#  chmod 0440 /etc/sudoers.d/pks
USER pks
