FROM debian:trixie-slim

ARG ZEPHYR_REPO=https://github.com/zephyrproject-rtos/zephyr
ARG ZEPHYR_VERSION=main

# OS dependencies and packages

ENV VIRTUAL_ENV=/opt/venv
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
  apt-get -y update \
  && apt-get -y install --no-install-recommends \
  ca-certificates \
  cmake \
  device-tree-compiler \
  git \
  ninja-build \
  python3 \
  python3-pip \
  python3-venv \
  ccache \
  wget \
  python3-dev \
  python3-tk \
  xz-utils \
  file \
  make \
  gcc \
  gcc-multilib \
  g++-multilib \
  libsdl2-dev \
  libmagic1 \
  && python3 -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

# West

RUN --mount=type=cache,target=/root/.cache/pip,sharing=locked \
  pip install "wheel>=0,<1" "west>=1,<2"

# Zephyr
WORKDIR /docs
RUN \
  west init -m $ZEPHYR_REPO --mr $ZEPHYR_VERSION ./zephyrproject \
  && cd ./zephyrproject \
  && west update -n -o=--depth=1 \
  && west zephyr-export \
  && west packages pip --install

# Docs pre-requisites
RUN \
  pip install -U -r ./zephyrproject/zephyr/doc/requirements.txt

# llms.txt generation (https://github.com/NVIDIA/sphinx-llm)
RUN pip install sphinx-llm

RUN \
  apt-get -y update \
  && apt-get -y install --no-install-recommends \
  doxygen \
  graphviz \
  librsvg2-bin \
  imagemagick

COPY entrypoint.sh /entrypoint.sh
COPY scripts /scripts
RUN chmod +x /entrypoint.sh /scripts/*.sh

# Zephyr SDK, only when the hardware feature tables are wanted. Those are
# derived from each board's devicetree, harvested by configuring every board
# with twister, which fails in verify-toolchain.cmake without target
# toolchains. The SDK adds several GB to the image, so it is opt-in.
ARG INSTALL_ZEPHYR_SDK=0
RUN if [ "$INSTALL_ZEPHYR_SDK" = "1" ]; then \
      /scripts/install-zephyr-sdk.sh --zephyr-root /docs/zephyrproject/zephyr; \
    fi

VOLUME /output
WORKDIR /docs/zephyrproject/zephyr/doc

ENTRYPOINT ["/entrypoint.sh"]
CMD ["html"]