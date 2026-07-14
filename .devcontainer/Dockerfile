# =============================================================================================
# cpp-toolchain - multi-stage build
#
#   Stages, each selectable via `docker build --target <stage>`:
#     runtime : minimal C++ runtime (libc/libgcc/libstdc++) - deploy base for compiled binaries
#     build   : runtime + compilers, build systems and dependency managers - CI/compile image
#     dev     : build   + static analysis, debug, docs, editors, shells - full dev environment
#
#   The stages form a superset chain (dev > build > runtime), so `--target dev` yields the full
#   image while `--target runtime` / `--target build` stop early for leaner images.
#
#   SSH remote access is an opt-in extra layer, built separately on top of the `dev` image via
#   ./ssh_support.dockerfile (see docker-compose.yaml `ssh` profile / README > Remote access).
# =============================================================================================

# ---------------------------------------------------------------------------------------------
# Stage: runtime - minimal image able to *run* binaries produced by the `build` stage.
# ---------------------------------------------------------------------------------------------
ARG BASE_IMAGE=ubuntu:latest
FROM ${BASE_IMAGE} AS runtime
ARG DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-c"]

# Latest C++ runtime libraries, pulled from the same PPA the `build` stage installs GCC from, so
# `--target runtime` can execute binaries linked against the newest libstdc++. The apt machinery
# needed only to register the PPA is purged afterwards to keep this stage lean (the `build` stage
# re-installs its own prerequisites on top).
RUN apt-get update -qqy \
    && apt-get install -qqy --no-install-recommends \
        ca-certificates tzdata \
        gnupg software-properties-common \
    && add-apt-repository -y ppa:ubuntu-toolchain-r/test \
    && apt-get update -qqy \
    && apt-get install -qqy --no-install-recommends \
        libc6 libgcc-s1 libstdc++6 \
    && apt-get purge -y --auto-remove gnupg software-properties-common \
    && rm -rf /var/lib/apt/lists/*

CMD ["/bin/bash"]

# ---------------------------------------------------------------------------------------------
# Stage: build - everything required to *compile* C++ (compilers, build systems, dep managers).
# ---------------------------------------------------------------------------------------------
FROM runtime AS build
ARG DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-c"]

ENV TOOLCHAIN_TMP_DIR=/tmp/install_toolchain

# Basics / installation prerequisites
#   openssh-client (not the `ssh` metapackage) so no SSH *server* is shipped here: remote access
#   is an opt-in layer (see ssh_support.dockerfile).
RUN apt update -qqy && apt install -qqy --no-install-recommends \
        ca-certificates debian-keyring                      \
        gpg gpg-agent gnupg                                 \
        software-properties-common lsb-release apt-utils    \
        python3 pip                                         \
   && add-apt-repository -y ppa:ubuntu-toolchain-r/test     \
   && apt update -qqy && apt install -qqy --no-install-recommends \
        wget openssh-client                                 \
        sudo tzdata curl libssl-dev                         \
        less tar zip unzip gzip                             \
        build-essential pkg-config                          \
        # build: CMake generators
        make ninja-build                                    \
        # build: cache
        ccache                                              \
        # versioning
        git                                                 \
    && rm -rf /var/lib/apt/lists/*

# C++ toolchain: cross-compilation binutils + dev headers
RUN apt update -qqy && apt install -qqy --no-install-recommends \
        libc6-dev libc6-arm64-cross                             \
        binutils-aarch64-linux-gnu binutils-powerpc64-linux-gnu \
    && rm -rf /var/lib/apt/lists/*

# Build: CMake (https://apt.kitware.com/)
COPY ./scripts/cmake.sh ${TOOLCHAIN_TMP_DIR}/scripts/cmake.sh
WORKDIR ${TOOLCHAIN_TMP_DIR}
ARG CMAKE_VERSION='latest'
RUN script_path=${TOOLCHAIN_TMP_DIR}/scripts/cmake.sh;                          \
    echo -e "[C++ toolchain] Installing CMAKE_VERSION=[$CMAKE_VERSION] ..." ;   \
    chmod +x ${script_path}                                                     \
    && ${script_path} --silent=yes --alias=yes --versions="$CMAKE_VERSION"      \
    && rm -rf /var/lib/apt/lists/*

# Build: Bazel (https://bazel.build/install/ubuntu)
ARG OPT_IN_INTEGRATE_BAZEL='no'
RUN if [[ "${OPT_IN_INTEGRATE_BAZEL}" = "y" ]]; then                    \
        apt update -qqy && apt install -qqy --no-install-recommends     \
            apt-transport-https curl gnupg                              \
        && curl -fsSL https://bazel.build/bazel-release.pub.gpg | gpg --dearmor >bazel-archive-keyring.gpg \
        && mv bazel-archive-keyring.gpg /usr/share/keyrings             \
        && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/bazel-archive-keyring.gpg] https://storage.googleapis.com/bazel-apt stable jdk1.8" | sudo tee /etc/apt/sources.list.d/bazel.list \
        && apt update -qqy && apt install -qqy --no-install-recommends  \
            bazel                                                       \
        && rm -rf /var/lib/apt/lists/*                                  \
        ;                                                               \
    fi

# Dependency managers
ENV VCPKG_URL       https://github.com/microsoft/vcpkg/archive/master.tar.gz
RUN \
    # vcpkg
    wget -qO vcpkg.tar.gz ${VCPKG_URL}                          \
    && mkdir /opt/vcpkg                                         \
    && tar xf vcpkg.tar.gz --strip-components=1 -C /opt/vcpkg   \
    && /opt/vcpkg/bootstrap-vcpkg.sh -disableMetrics            \
    && ln -s /opt/vcpkg/vcpkg /usr/local/bin/vcpkg
RUN \
    # conan
    #   work-around for pip "error: externally-managed-environment"
    apt update -qqy && apt install -qqy --no-install-recommends \
        pipx                                                    \
    && (pipx install conan > /dev/null 2>&1)                    \
    && rm -rf /var/lib/apt/lists/*

# C++ toolchain: GNU/GCC
#   apt update here: gcc.sh only refreshes lists when it has to *add* the ubuntu-toolchain-r PPA,
#   which the `runtime` stage already registered, so it relies on a populated apt cache.
COPY ./scripts/gcc.sh ${TOOLCHAIN_TMP_DIR}/scripts/gcc.sh
WORKDIR ${TOOLCHAIN_TMP_DIR}
ARG GCC_VERSIONS='latest-stable'
RUN apt-get update -qqy                                                       \
    && script_path=${TOOLCHAIN_TMP_DIR}/scripts/gcc.sh                        \
    && echo -e "[C++ toolchain] Installing GCC_VERSIONS=[$GCC_VERSIONS] ..."  \
    && chmod +x ${script_path}                                               \
    && ${script_path} --silent=yes --alias=yes --versions="$GCC_VERSIONS"

# C++ toolchain: LLVM/Clang (https://apt.llvm.org/)
#   `--minimalistic`: register only the clang/clang++ compilers here. The rest of the LLVM
#   toolchain (clang-tidy, clang-format, clangd, lldb, scan-build, ...) is a static-analysis /
#   dev concern and is wired up in the `dev` stage below.
COPY ./scripts/llvm.sh ${TOOLCHAIN_TMP_DIR}/scripts/llvm.sh
WORKDIR ${TOOLCHAIN_TMP_DIR}
ARG LLVM_VERSIONS='latest-stable'
RUN script_path=${TOOLCHAIN_TMP_DIR}/scripts/llvm.sh;                           \
    echo -e "[C++ toolchain] Installing LLVM_VERSIONS=[$LLVM_VERSIONS] ..." ;   \
    chmod +x ${script_path}                                                     \
    && ${script_path} --silent=yes --alias=yes --minimalistic --versions="$LLVM_VERSIONS"

# Build: Build2-0.16.0 (depends on a compiler)
ARG OPT_IN_INTEGRATE_BUILD2='no'
RUN if [[ "${OPT_IN_INTEGRATE_BUILD2}" = "y" ]]; then                               \
        mkdir -p /tmp/build2-build && cd /tmp/build2-build                          \
        && curl -sSfO https://download.build2.org/0.16.0/build2-install-0.16.0.sh   \
        && echo '4d2babfaff6d0412e0ab61a3d3c68a87de54c0779254d62f4569b44a56c6ea08 *build2-install-0.16.0.sh' | shasum -a 256 -c \
        && sh build2-install-0.16.0.sh                                              \
            --yes                                                                   \
            --cxx clang++                                                           \
            --sudo false                                                            \
            --jobs $(nproc)                                                         \
        ;                                                                           \
    fi

# Cleanup (keeps the published `build` image lean; `dev` re-runs `apt update` on top)
RUN apt-get clean && rm -rf /var/lib/apt/lists/*

CMD ["/bin/bash"]

# ---------------------------------------------------------------------------------------------
# Stage: dev - full development environment.
#   Adds static-analysis & debug tooling, documentation generators, editors and shells on top of
#   the compile-only `build` stage. This is the image the devcontainer / published `-dev` uses.
# ---------------------------------------------------------------------------------------------
FROM build AS dev
ARG DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-c"]

# Tooling: static analysis, debug, documentation, editors, versioning extras, misc
RUN apt update -qqy && apt install -qqy --no-install-recommends \
        # analysis
        valgrind cppcheck iwyu                              \
        # debug
        gdb                                                 \
        # versioning
        subversion                                          \
        # documentation
        doxygen graphviz                                    \
        # editors
        emacs nano vim                                      \
        # misc
        docker-compose jq ripgrep                           \
    && rm -rf /var/lib/apt/lists/*

# C++ toolchain: LLVM/Clang - full toolchain (clang-tidy, clang-format, clangd, lldb, scan-build).
#   Re-runs llvm.sh non-minimalistically to register the analysis/dev tools alongside the
#   clang/clang++ compilers already installed by the `build` stage.
COPY ./scripts/llvm.sh ${TOOLCHAIN_TMP_DIR}/scripts/llvm.sh
WORKDIR ${TOOLCHAIN_TMP_DIR}
ARG LLVM_VERSIONS='latest-stable'
RUN script_path=${TOOLCHAIN_TMP_DIR}/scripts/llvm.sh;                                   \
    echo -e "[C++ dev] Installing LLVM dev tools LLVM_VERSIONS=[$LLVM_VERSIONS] ..." ;  \
    chmod +x ${script_path}                                                             \
    && ${script_path} --silent=yes --alias=yes --versions="$LLVM_VERSIONS"              \
    && rm -rf /var/lib/apt/lists/*

# Tooling: shells - bash, zsh
RUN apt update -qqy && apt install -qqy --no-install-recommends \
        bash zsh \
    # ZSH: Default powerline10k theme, no plugins installed
    && yes | sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v1.1.5/zsh-in-docker.sh)" \
    && rm -rf /var/lib/apt/lists/*
# see https://stackoverflow.com/questions/55987337/visual-studio-code-remote-containers-change-shell

# Cleanup
RUN apt clean \
    && rm -rf ${TOOLCHAIN_TMP_DIR} \
    && rm -rf /var/lib/apt/lists/*

CMD ["/bin/bash"]
