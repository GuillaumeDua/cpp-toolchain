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
# Stage: runtime - minimal image able to run binaries produced by the `build` stage.
# ---------------------------------------------------------------------------------------------
ARG BASE_IMAGE=ubuntu:latest
FROM ${BASE_IMAGE} AS runtime
ARG DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-c"]

# Latest C++ runtime libraries, pulled from the same PPA the `build` stage installs GCC from,
# so `--target runtime` can execute binaries linked against the newest libstdc++.
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
# Stage: build - everything required to compile C++ (compilers, build systems, dep managers).
# ---------------------------------------------------------------------------------------------
FROM runtime AS build
ARG DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-c"]

ENV TOOLCHAIN_TMP_DIR=/tmp/install_toolchain

# Basics / installation prerequisites
#   openssh-client (not the `ssh` metapackage) so no SSH server is shipped here:
#   remote access is an opt-in layer (see ssh_support.dockerfile).
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

# Git: trust any bind-mounted repository regardless of its owner (disables Git's "dubious ownership" check).
#   Written system-wide to /etc/gitconfig, so it applies to every user and every downstream stage:
#   consumer CI that mounts a checkout owned by another UID can then run git with no extra setup.
#   Acceptable for an ephemeral CI/build image.
RUN git config --system --add safe.directory '*'

# C++ toolchain: native libc dev headers.
#   Cross-arch toolchains (opt-in, per target) are installed at the end of this stage by binutils.sh,
#   so the expensive layers below stay shared between the normal and cross-arch image variants.
RUN apt update -qqy && apt install -qqy --no-install-recommends \
        libc6-dev                                              \
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
#   Bazel's apt repository ships amd64 only (no arm64 debs), so this opt-in step is
#   guarded to amd64 - on other architectures it is skipped (use Bazelisk instead).
ARG OPT_IN_INTEGRATE_BAZEL='no'
RUN if [[ "${OPT_IN_INTEGRATE_BAZEL}" = "y" ]] && [[ "$(dpkg --print-architecture)" != "amd64" ]]; then           \
        echo "[bazel] apt repository is amd64-only, skipping on $(dpkg --print-architecture)";                     \
    elif [[ "${OPT_IN_INTEGRATE_BAZEL}" = "y" ]]; then                    \
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
    # conan (with work-around for pip "error: externally-managed-environment")
    apt update -qqy && apt install -qqy --no-install-recommends \
        pipx                                                    \
    && (pipx install conan > /dev/null 2>&1)                    \
    && rm -rf /var/lib/apt/lists/*

# C++ toolchain: GNU/GCC
#   apt update here: gcc.sh only refreshes lists when it has to add the ubuntu-toolchain-r PPA,
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
#   `--minimalistic`: register only the clang/clang++ compilers here.
#   The rest of the LLVM toolchain (clang-tidy, clang-format, clangd, lldb, scan-build, ...) is a static-analysis / dev concern and is wired up in the `dev` stage below.
COPY ./scripts/llvm.sh ${TOOLCHAIN_TMP_DIR}/scripts/llvm.sh
WORKDIR ${TOOLCHAIN_TMP_DIR}
ARG LLVM_VERSIONS='latest-stable'
RUN script_path=${TOOLCHAIN_TMP_DIR}/scripts/llvm.sh;                           \
    echo -e "[C++ toolchain] Installing LLVM_VERSIONS=[$LLVM_VERSIONS] ..." ;   \
    chmod +x ${script_path}                                                     \
    && ${script_path} --silent=yes --alias=yes --minimalistic --versions="$LLVM_VERSIONS"

# Build: Build2 (depends on a compiler)
#   BUILD2_VERSION is the single source of truth (bumped by Renovate, see renovate.json).
#   The install script is verified against build2's per-release `.sha256` sidecar,
#    rather than a hash pinned here, so a version bump stays a one-line change.
# renovate: datasource=github-tags depName=build2/build2-toolchain extractVersion=^v(?<version>.+)$
ARG BUILD2_VERSION=0.16.0
ARG OPT_IN_INTEGRATE_BUILD2='no'
RUN if [[ "${OPT_IN_INTEGRATE_BUILD2}" = "y" ]]; then                               \
        mkdir -p /tmp/build2-build && cd /tmp/build2-build                          \
        && script="build2-install-${BUILD2_VERSION}.sh"                            \
        && base_url="https://download.build2.org/${BUILD2_VERSION}"                \
        && curl -sSfO "${base_url}/${script}"                                       \
        && curl -sSfO "${base_url}/${script}.sha256"                               \
        && shasum -a 256 -c "${script}.sha256"                                      \
        && sh "${script}"                                                           \
            --yes                                                                   \
            --cxx clang++                                                           \
            --sudo false                                                            \
            --jobs $(nproc)                                                         \
        ;                                                                           \
    fi

# C++ toolchain: per-target cross toolchain(s) via g++-<triplet>
#   (pulls cross binutils + libc + libgcc + libstdc++, so C/C++ cross-compilation links; clang auto-detects it).
#   Falls back to bare binutils + cross-libc where no cross-g++ exists. Owned by binutils.sh, not gcc.sh (which owns --multilib).
#   Kept last in the stage so it is a single opt-in layer on top of the shared toolchain:
#   BINUTILS_TARGETS='' (the default) installs nothing - the lean/normal variant - while a triplet list builds the cross-arch variant.
COPY ./scripts/binutils.sh ${TOOLCHAIN_TMP_DIR}/scripts/binutils.sh
WORKDIR ${TOOLCHAIN_TMP_DIR}
ARG BINUTILS_TARGETS=''
RUN script_path=${TOOLCHAIN_TMP_DIR}/scripts/binutils.sh;                                              \
    echo -e "[C++ toolchain] Installing cross toolchains BINUTILS_TARGETS=[$BINUTILS_TARGETS] ...";    \
    chmod +x ${script_path}                                                                            \
    && ${script_path} --silent=yes --targets="$BINUTILS_TARGETS"                                       \
    && rm -rf /var/lib/apt/lists/*

# Cleanup (keeps the published `build` image lean; `dev` re-runs `apt update` on top)
RUN apt-get clean && rm -rf /var/lib/apt/lists/*

CMD ["/bin/bash"]

# ---------------------------------------------------------------------------------------------
# Stage: static-analysis - static-analysis tooling for CI / PR evaluation, on top of `build`.
#   Registers the full LLVM toolchain - clang-tidy, etc. -,
#   (the `build` stage installed the clang packages minimalistically),
#   and adds the dedicated static analysers (cppcheck, iwyu).
# ---------------------------------------------------------------------------------------------
FROM build AS static-analysis
ARG DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-c"]

# C++ toolchain: LLVM/Clang - full toolchain (clang-tidy, clang-format, clangd, lldb, scan-build).
#   Re-runs llvm.sh non-minimalistically to register the analysis tools alongside the clang/clang++
#   compilers already installed by the `build` stage.
COPY ./scripts/llvm.sh ${TOOLCHAIN_TMP_DIR}/scripts/llvm.sh
WORKDIR ${TOOLCHAIN_TMP_DIR}
ARG LLVM_VERSIONS='latest-stable'
RUN script_path=${TOOLCHAIN_TMP_DIR}/scripts/llvm.sh;                                       \
    echo -e "[C++ analysis] Registering LLVM tools LLVM_VERSIONS=[$LLVM_VERSIONS] ..." ;    \
    chmod +x ${script_path}                                                                 \
    && ${script_path} --silent=yes --alias=yes --versions="$LLVM_VERSIONS"                  \
    && rm -rf /var/lib/apt/lists/*

# Dedicated static analysers
RUN apt update -qqy && apt install -qqy --no-install-recommends \
        cppcheck iwyu \
    && rm -rf /var/lib/apt/lists/*

CMD ["/bin/bash"]

# ---------------------------------------------------------------------------------------------
# Stage: documentation - documentation generation for CI, on top of `build`.
#   Needs the `build` toolchain (CMake `doc` targets, processing the checked-out sources) plus the
#   doxygen/graphviz generators and the coverage tooling both toolchains' `doc` targets can call.
# ---------------------------------------------------------------------------------------------
FROM build AS documentation
ARG DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-c"]

# Coverage: register the unversioned Clang coverage commands (llvm-cov, llvm-profdata).
#   The `build` stage installed clang `--minimalistic` (compilers only); re-run llvm.sh in
#   `--coverage` mode to add the llvm-cov/llvm-profdata alternatives - the GCC side (gcov) already
#   ships with GCC and lcov (`genhtml`) is installed below.
COPY ./scripts/llvm.sh ${TOOLCHAIN_TMP_DIR}/scripts/llvm.sh
WORKDIR ${TOOLCHAIN_TMP_DIR}
ARG LLVM_VERSIONS='latest-stable'
RUN script_path=${TOOLCHAIN_TMP_DIR}/scripts/llvm.sh;                                            \
    echo -e "[C++ coverage] Registering LLVM coverage tools LLVM_VERSIONS=[$LLVM_VERSIONS] ..."; \
    chmod +x ${script_path}                                                                      \
    && ${script_path} --silent=yes --alias=yes --coverage --versions="$LLVM_VERSIONS"            \
    && rm -rf /var/lib/apt/lists/*

# Documentation: Doxygen (pre-built binary - Ubuntu's apt package lags upstream) + graphviz (`dot`).
#   lcov (`genhtml`) covers the GCC coverage path of CMake `doc` targets; gcov ships with GCC already.
# renovate: datasource=github-releases depName=doxygen/doxygen versioning=regex:^Release_(?<major>\d+)_(?<minor>\d+)_(?<patch>\d+)$
ARG DOXYGEN_RELEASE=Release_1_17_0
COPY ./scripts/doxygen.sh ${TOOLCHAIN_TMP_DIR}/scripts/doxygen.sh
RUN apt update -qqy && apt install -qqy --no-install-recommends graphviz lcov \
    && rm -rf /var/lib/apt/lists/*                                            \
    && chmod +x ${TOOLCHAIN_TMP_DIR}/scripts/doxygen.sh                       \
    && ${TOOLCHAIN_TMP_DIR}/scripts/doxygen.sh "${DOXYGEN_RELEASE}"           \
    && rm -rf /var/lib/apt/lists/*

CMD ["/bin/bash"]

# ---------------------------------------------------------------------------------------------
# Stage: dev - full development environment.
#   Inherits `static-analysis`, re-adds the `documentation` tools,
#   and layers on the interactive dev tooling (dynamic analysis, debugger, editors, shells, misc).
#   Published `-dev` / devcontainer.
# ---------------------------------------------------------------------------------------------
FROM static-analysis AS dev
ARG DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-c"]

# Tooling: documentation (re-added from the `documentation` stage, since dev inherits the
#          `static-analysis` sibling), dynamic analysis, debug, versioning extras, editors, misc
RUN apt update -qqy && apt install -qqy --no-install-recommends \
        # documentation (doxygen itself is installed as a pre-built binary below; graphviz -> `dot`, lcov -> coverage `genhtml`)
        graphviz lcov                                       \
        # dynamic analysis
        valgrind                                            \
        # debug
        gdb                                                 \
        # versioning
        subversion                                          \
        # editors
        emacs nano vim                                      \
        # misc
        docker-compose jq ripgrep                           \
    && rm -rf /var/lib/apt/lists/*

# Documentation: Doxygen pre-built binary - re-added here because dev inherits `static-analysis`,
#                not the sibling `documentation` stage (mirrors the graphviz re-add above).
# renovate: datasource=github-releases depName=doxygen/doxygen versioning=regex:^Release_(?<major>\d+)_(?<minor>\d+)_(?<patch>\d+)$
ARG DOXYGEN_RELEASE=Release_1_17_0
COPY ./scripts/doxygen.sh ${TOOLCHAIN_TMP_DIR}/scripts/doxygen.sh
RUN chmod +x ${TOOLCHAIN_TMP_DIR}/scripts/doxygen.sh \
    && ${TOOLCHAIN_TMP_DIR}/scripts/doxygen.sh "${DOXYGEN_RELEASE}" \
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
