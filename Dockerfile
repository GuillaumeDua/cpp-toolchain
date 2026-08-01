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
#   .devcontainer/ssh_support.dockerfile (see its docker-compose.yaml `ssh` profile / README > Remote access).
# =============================================================================================

# ---------------------------------------------------------------------------------------------
# Pinned versions - the single source of truth for what these images contain.
#
#   Every version is pinned and `# renovate:`-annotated,
#   so Renovate owns the updates and this block *is* the image manifest: scripts/details/render-manifest.py reads these same lines to build each release note.
#   Nothing resolves at build time, so two builds of one commit produce the same image.
#
#   Declared once, before the first FROM, and re-declared bare (`ARG LLVM_VERSIONS`) in each stage that needs one.
#   A per-stage default would be a second value for Renovate to keep in step.
#
#   The annotation must sit directly above its ARG,
#   and follow the field order datasource / depName / versioning / extractVersion - that is what renovate.json's custom manager matches. 
#   Values must be unquoted: it captures `\S+`, so quotes would be read as part of them.
# ---------------------------------------------------------------------------------------------

# Base image.
#   Tracked by its own renovate.json manager rather than the annotation above,
#   because a digest pin needs currentValue and currentDigest captured separately.
ARG BASE_IMAGE=ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90

# Ubuntu archive snapshot (https://snapshot.ubuntu.com).
#   freezes apt to a point in time, so the distro packages installed below resolve identically on every rebuild without pinning each one.
#   The only pin Renovate cannot own - a datasource must enumerate available versions,
#   and the service accepts any timestamp without publishing an index.
#   Bumped by .github/workflows/ubuntu-snapshot.yml.
ARG UBUNTU_SNAPSHOT=20260720T000000Z

# GCC, from ppa:ubuntu-toolchain-r/test.
#   Only major versions exist as packages (g++-15).
#   The `\.\d+\.\d+$` tail keeps this on released tags: gcc-mirror also carries basepoints and
#   prereleases, and the PPA's newest series is a dated trunk snapshot, not a release.
# renovate: datasource=github-tags depName=gcc-mirror/gcc extractVersion=^releases/gcc-(?<version>\d+)\.\d+\.\d+$
ARG GCC_VERSIONS=15

# LLVM/Clang, from apt.llvm.org.
#   Same shape: major only, released tags only - llvm-project publishes release candidates (llvmorg-23.1.0-rc1) that would otherwise propose a major the apt repo lacks.
# renovate: datasource=github-releases depName=llvm/llvm-project extractVersion=^llvmorg-(?<version>\d+)\.\d+\.\d+$
ARG LLVM_VERSIONS=22

# CMake, from apt.kitware.com.
#   cmake.sh resolves this against `apt-cache madison`.
#   The strict x.y.z tail drops release candidates (v4.4.0-rc3) rather than relying on Renovate's
#   unstable-filtering default, matching the GCC and LLVM patterns above.
# renovate: datasource=github-releases depName=Kitware/CMake extractVersion=^v(?<version>\d+\.\d+\.\d+)$
ARG CMAKE_VERSION=4.4.0

# vcpkg release tag - dated, so loose versioning rather than semver.
# renovate: datasource=github-tags depName=microsoft/vcpkg versioning=loose
ARG VCPKG_VERSION=2026.06.24

# renovate: datasource=pypi depName=conan
ARG CONAN_VERSION=2.31.1

# Doxygen tags use underscores (Release_1_17_0) while the download asset uses dots - doxygen.sh derives both.
# renovate: datasource=github-releases depName=doxygen/doxygen versioning=regex:^Release_(?<major>\d+)_(?<minor>\d+)_(?<patch>\d+)$
ARG DOXYGEN_RELEASE=Release_1_17_0

# The install script is verified against build2's per-release `.sha256` sidecar rather than a hash pinned here, so a version bump stays a one-line change.
# renovate: datasource=github-tags depName=build2/build2-toolchain extractVersion=^v(?<version>.+)$
ARG BUILD2_VERSION=0.16.0

# oh-my-zsh publishes no releases and no tags - a commit is the only stable identifier it has, so it
#   is pinned by SHA and Renovate follows the branch head via the git-refs datasource.
#   Matched by its own renovate.json manager: a digest pin needs currentDigest rather than
#   currentValue, which the annotation manager above cannot express.
# renovate: datasource=git-refs depName=https://github.com/ohmyzsh/ohmyzsh currentValue=master
ARG OHMYZSH_COMMIT=7ea697fd8138550ddf7262456d412f0dcd1cbf84

# renovate: datasource=github-tags depName=romkatv/powerlevel10k extractVersion=^v(?<version>.+)$
ARG POWERLEVEL10K_VERSION=1.20.0

# ---------------------------------------------------------------------------------------------
# Stage: runtime - minimal image able to run binaries produced by the `build` stage.
# ---------------------------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS runtime
ARG DEBIAN_FRONTEND=noninteractive
ARG UBUNTU_SNAPSHOT
SHELL ["/bin/bash", "-c"]

# apt -> Ubuntu archive snapshot, so every stage below installs from a frozen archive.
#
#   snapshot.ubuntu.com is HTTPS-only and the base image carries no CA bundle,
#   so ca-certificates is bootstrapped from the stock archive first,
#   then every package is realigned onto the snapshot - after which no Ubuntu archive content comes from a moving source.
#   The third-party repositories added later (the toolchain PPA, apt.llvm.org, apt.kitware.com, etc.) have no snapshot service,
#   so the ARGs above pin a major or an upstream version there, not a deb revision.
#
#   This realignment runs before the toolchain PPA is added, and that ordering is load-bearing:
#   run it afterwards and apt-cache policy would start seeing PPA candidates for libstdc++6 and friends.
#
#   That realignment is not cosmetic.
#   The bootstrap is the one moment this image talks to the live archive,
#   and ca-certificates hard-depends on openssl,
#   so apt drags openssl and libssl3t64 forward to whatever the live archive publishes today.
#   The frozen archive still carries the older pair, and libssl-dev depends on its runtime with `=`,
#   so a stage asking for any -dev package later fails on held broken packages.
#   Downgrades are therefore allowed: the snapshot, not the live archive, decides what is installed.
#
#   Diffing installed against candidate, rather than naming the packages the bootstrap moves today,
#   keeps this correct if ca-certificates grows a dependency:
#   the failure it prevents stays silent until a -dev counterpart is requested, several stages later.
#
#   Noble uses deb822 (/etc/apt/sources.list.d/ubuntu.sources); the legacy sources.list is rewritten too, so this keeps working if the base image layout changes.
#   The snapshot service unifies every architecture under a single /ubuntu/ path:
#       there is no /ubuntu-ports/ equivalent - so the non-amd64 ports.ubuntu.com sources are redirected there too.
RUN apt-get update -qqy                                                                             \
    && apt-get install -qqy --no-install-recommends ca-certificates                                 \
    && for src in /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources; do                  \
           [[ -f "${src}" ]] && sed -i -E                                                           \
               -e "s#https?://(archive|security)\.ubuntu\.com/ubuntu/?#https://snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT}/#g" \
               -e "s#https?://ports\.ubuntu\.com/ubuntu-ports/?#https://snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT}/#g" \
               "${src}";                                                                            \
           true;                                                                                    \
       done                                                                                         \
    && apt-get update -qqy                                                                          \
    && mapfile -t realign < <(apt-cache policy $(dpkg-query -W -f='${binary:Package}\n')            \
           | awk '/^[^ ]/{pkg=$1;sub(/:$/,"",pkg)} /^ +Installed:/{inst=$2} /^ +Candidate:/{if(inst!=$2 && $2!="(none)" && inst!="(none)")print pkg"="$2}') \
    && if ((${#realign[@]})); then                                                                  \
           echo "[C++ toolchain] realigning onto the snapshot: ${realign[*]}";                      \
           apt-get install -qqy --no-install-recommends --allow-downgrades "${realign[@]}";         \
       fi                                                                                           \
    && echo "[C++ toolchain] apt frozen at snapshot ${UBUNTU_SNAPSHOT}"

# C++ runtime libraries, pulled from the same PPA the `build` stage installs GCC from,
# so `--target runtime` can execute binaries linked against the pinned libstdc++.
RUN apt-get update -qqy \
    && apt-get install -qqy --no-install-recommends \
        tzdata \
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
#       consumer CI that mounts a checkout owned by another UID can then run git with no extra setup.
#   Acceptable for an ephemeral CI/build image.
RUN git config --system --add safe.directory '*'

# C++ toolchain: native libc dev headers.
#   Cross-arch toolchains (opt-in, per target) are installed at the end of this stage by binutils.sh,
#   so the expensive layers below stay shared between the normal and cross-arch image variants.
RUN apt update -qqy && apt install -qqy --no-install-recommends \
        libc6-dev                                              \
    && rm -rf /var/lib/apt/lists/*

# Build: CMake (https://apt.kitware.com/)
COPY ./scripts/install/cmake.sh ${TOOLCHAIN_TMP_DIR}/scripts/cmake.sh
WORKDIR ${TOOLCHAIN_TMP_DIR}
ARG CMAKE_VERSION
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
ARG VCPKG_VERSION
RUN \
    # vcpkg, from a release tag rather than `master`: GitHub's tarball for a tag is immutable,
    # so the same VCPKG_VERSION always yields the same tree.
    wget -qO vcpkg.tar.gz "https://github.com/microsoft/vcpkg/archive/refs/tags/${VCPKG_VERSION}.tar.gz" \
    && mkdir /opt/vcpkg                                         \
    && tar xf vcpkg.tar.gz --strip-components=1 -C /opt/vcpkg   \
    && /opt/vcpkg/bootstrap-vcpkg.sh -disableMetrics            \
    && ln -s /opt/vcpkg/vcpkg /usr/local/bin/vcpkg
ARG CONAN_VERSION
RUN \
    # conan (with work-around for pip "error: externally-managed-environment")
    apt update -qqy && apt install -qqy --no-install-recommends \
        pipx                                                    \
    && (pipx install "conan==${CONAN_VERSION}" > /dev/null 2>&1) \
    && rm -rf /var/lib/apt/lists/*

# C++ toolchain: GNU/GCC
#   apt update here: gcc.sh only refreshes lists when it has to add the ubuntu-toolchain-r PPA,
#   which the `runtime` stage already registered, so it relies on a populated apt cache.
COPY ./scripts/install/gcc.sh ${TOOLCHAIN_TMP_DIR}/scripts/gcc.sh
WORKDIR ${TOOLCHAIN_TMP_DIR}
ARG GCC_VERSIONS
RUN apt-get update -qqy                                                       \
    && script_path=${TOOLCHAIN_TMP_DIR}/scripts/gcc.sh                        \
    && echo -e "[C++ toolchain] Installing GCC_VERSIONS=[$GCC_VERSIONS] ..."  \
    && chmod +x ${script_path}                                               \
    && ${script_path} --silent=yes --alias=yes --versions="$GCC_VERSIONS"

# C++ toolchain: LLVM/Clang (https://apt.llvm.org/)
#   `--minimalistic`: register only the clang/clang++ compilers here.
#   The rest of the LLVM toolchain (clang-tidy, clang-format, clangd, lldb, scan-build, ...) is a static-analysis / dev concern and is wired up in the `dev` stage below.
COPY ./scripts/install/llvm.sh ${TOOLCHAIN_TMP_DIR}/scripts/llvm.sh
WORKDIR ${TOOLCHAIN_TMP_DIR}
ARG LLVM_VERSIONS
RUN script_path=${TOOLCHAIN_TMP_DIR}/scripts/llvm.sh;                           \
    echo -e "[C++ toolchain] Installing LLVM_VERSIONS=[$LLVM_VERSIONS] ..." ;   \
    chmod +x ${script_path}                                                     \
    && ${script_path} --silent=yes --alias=yes --minimalistic --versions="$LLVM_VERSIONS"

# Build: Build2 (depends on a compiler)
#   BUILD2_VERSION is declared once at the top of this file (bumped by Renovate).
ARG BUILD2_VERSION
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
COPY ./scripts/install/binutils.sh ${TOOLCHAIN_TMP_DIR}/scripts/binutils.sh
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
#   Registers the full LLVM toolchain - clang-tidy, etc. (the `build` stage installed the clang packages minimalistically),
#   and adds the dedicated static analysers (cppcheck, iwyu).
# ---------------------------------------------------------------------------------------------
FROM build AS static-analysis
ARG DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-c"]

# C++ toolchain: LLVM/Clang - full toolchain (clang-tidy, clang-format, clangd, lldb, scan-build).
#   Re-runs llvm.sh non-minimalistically to register the analysis tools alongside the clang/clang++
#   compilers already installed by the `build` stage.
COPY ./scripts/install/llvm.sh ${TOOLCHAIN_TMP_DIR}/scripts/llvm.sh
WORKDIR ${TOOLCHAIN_TMP_DIR}
ARG LLVM_VERSIONS
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
COPY ./scripts/install/llvm.sh ${TOOLCHAIN_TMP_DIR}/scripts/llvm.sh
WORKDIR ${TOOLCHAIN_TMP_DIR}
ARG LLVM_VERSIONS
RUN script_path=${TOOLCHAIN_TMP_DIR}/scripts/llvm.sh;                                            \
    echo -e "[C++ coverage] Registering LLVM coverage tools LLVM_VERSIONS=[$LLVM_VERSIONS] ..."; \
    chmod +x ${script_path}                                                                      \
    && ${script_path} --silent=yes --alias=yes --coverage --versions="$LLVM_VERSIONS"            \
    && rm -rf /var/lib/apt/lists/*

# Documentation: Doxygen (pre-built binary - Ubuntu's apt package lags upstream) + graphviz (`dot`).
#   lcov (`genhtml`) covers the GCC coverage path of CMake `doc` targets; gcov ships with GCC already.
ARG DOXYGEN_RELEASE
COPY ./scripts/install/doxygen.sh ${TOOLCHAIN_TMP_DIR}/scripts/doxygen.sh
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
ARG DOXYGEN_RELEASE
COPY ./scripts/install/doxygen.sh ${TOOLCHAIN_TMP_DIR}/scripts/doxygen.sh
RUN chmod +x ${TOOLCHAIN_TMP_DIR}/scripts/doxygen.sh \
    && ${TOOLCHAIN_TMP_DIR}/scripts/doxygen.sh "${DOXYGEN_RELEASE}" \
    && rm -rf /var/lib/apt/lists/*

# Tooling: shells - bash, zsh, with oh-my-zsh + the powerlevel10k theme and no plugins.
#   [TO_TEST] Installed directly rather than through zsh-in-docker,
#   which hardcoded oh-my-zsh to `master` and powerlevel10k to its default branch with no way to pin either.
#   The two pieces most likely to change under a rebuild were the only ones left floating.
#   The generated .zshrc reproduces what zsh-in-docker wrote for this configuration.
ARG OHMYZSH_COMMIT
ARG POWERLEVEL10K_VERSION
RUN apt update -qqy && apt install -qqy --no-install-recommends       \
        bash zsh locales                                              \
    && rm -rf /var/lib/apt/lists/*                                    \
    # oh-my-zsh, pinned by commit: the repository publishes no tags at all.
    && git clone --quiet https://github.com/ohmyzsh/ohmyzsh.git "${HOME}/.oh-my-zsh"                 \
    && git -C "${HOME}/.oh-my-zsh" checkout --quiet "${OHMYZSH_COMMIT}"                              \
    # powerlevel10k, pinned by release tag.
    && git clone --quiet --depth 1 --branch "v${POWERLEVEL10K_VERSION}"                              \
        https://github.com/romkatv/powerlevel10k.git                                                 \
        "${HOME}/.oh-my-zsh/custom/themes/powerlevel10k"                                             \
    && printf '%s\n'                                                  \
        "export LANG='en_US.UTF-8'"                                   \
        "export LANGUAGE='en_US:en'"                                  \
        "export LC_ALL='en_US.UTF-8'"                                 \
        "export TERM=xterm"                                           \
        ""                                                            \
        "##### Zsh/Oh-my-Zsh Configuration"                           \
        "export ZSH=\"${HOME}/.oh-my-zsh\""                           \
        ""                                                            \
        "ZSH_THEME=\"powerlevel10k/powerlevel10k\""                   \
        "plugins=()"                                                  \
        ""                                                            \
        "source \$ZSH/oh-my-zsh.sh"                                   \
        "POWERLEVEL9K_SHORTEN_STRATEGY=\"truncate_to_last\""          \
        "POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(user dir vcs status)"     \
        "POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=()"                       \
        "POWERLEVEL9K_STATUS_OK=false"                                \
        "POWERLEVEL9K_STATUS_CROSS=true"                              \
        > "${HOME}/.zshrc"
# see https://stackoverflow.com/questions/55987337/visual-studio-code-remote-containers-change-shell

# Cleanup
RUN apt clean \
    && rm -rf ${TOOLCHAIN_TMP_DIR} \
    && rm -rf /var/lib/apt/lists/*

CMD ["/bin/bash"]
