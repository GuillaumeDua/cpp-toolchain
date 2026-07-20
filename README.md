# cpp-toolchain

Up-to-date C++ toolchain docker images for development, built as a multi-stage [`Dockerfile`](.devcontainer/Dockerfile) and published as five stages on:

- [DockerHub repository](https://hub.docker.com/repository/docker/guillaumedua/cpp-toolchain)
- [GHRC - GitHub Container Registry](https://github.com/GuillaumeDua/cpp-toolchain/pkgs/container/cpp-toolchain)

[![docker-build](https://github.com/GuillaumeDua/cpp-toolchain/actions/workflows/docker-build.yml/badge.svg)](https://github.com/GuillaumeDua/cpp-toolchain/actions/workflows/docker-build.yml)
[![docker-publish](https://github.com/GuillaumeDua/cpp-toolchain/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/GuillaumeDua/cpp-toolchain/actions/workflows/docker-publish.yml)

Published to **Docker Hub** and **GHCR** via [GitHub Actions](.github/workflows/docker-publish.yml) - see [Registries & tags](#registries--tags).

## Images

The [Dockerfile](.devcontainer/Dockerfile) is a multi-stage build: `runtime` → `build`, then `static-analysis` and `documentation` branch off `build`, and `dev` combines everything. All five stages are published to the single [`guillaumedua/cpp-toolchain`](https://hub.docker.com/repository/docker/guillaumedua/cpp-toolchain/general) repository, one **stage-prefixed tag** per stage, so any stage is available at any version. Locally, the same stages are selected with `docker build --target <stage>` (omitting `--target` builds `dev`, the last stage):

| Tag prefix | `--target` | Purpose | Size (`latest`) | Size (`experimental`) |
| ---------- | ---------- | ------- | --------------- | --------------------- |
| `runtime-` | `runtime` | Minimal C++ runtime (`libc`/`libstdc++`) to **run** compiled binaries | [![size](https://img.shields.io/docker/image-size/guillaumedua/cpp-toolchain/runtime-latest)](https://hub.docker.com/repository/docker/guillaumedua/cpp-toolchain/tags) | [![size](https://img.shields.io/docker/image-size/guillaumedua/cpp-toolchain/runtime-experimental)](https://hub.docker.com/repository/docker/guillaumedua/cpp-toolchain/tags) |
| `build-` | `build` | **Compile** C++: compilers, build systems, dependency managers (CI) | [![size](https://img.shields.io/docker/image-size/guillaumedua/cpp-toolchain/build-latest)](https://hub.docker.com/repository/docker/guillaumedua/cpp-toolchain/tags) | [![size](https://img.shields.io/docker/image-size/guillaumedua/cpp-toolchain/build-experimental)](https://hub.docker.com/repository/docker/guillaumedua/cpp-toolchain/tags) |
| `static-analysis-` | `static-analysis` | `build` + **static analysis** (clang-tidy/clang-format/scan-build, cppcheck, iwyu) for PR checks | [![size](https://img.shields.io/docker/image-size/guillaumedua/cpp-toolchain/static-analysis-latest)](https://hub.docker.com/repository/docker/guillaumedua/cpp-toolchain/tags) | [![size](https://img.shields.io/docker/image-size/guillaumedua/cpp-toolchain/static-analysis-experimental)](https://hub.docker.com/repository/docker/guillaumedua/cpp-toolchain/tags) |
| `documentation-` | `documentation` | `build` + **documentation** generators (doxygen, graphviz) | [![size](https://img.shields.io/docker/image-size/guillaumedua/cpp-toolchain/documentation-latest)](https://hub.docker.com/repository/docker/guillaumedua/cpp-toolchain/tags) | [![size](https://img.shields.io/docker/image-size/guillaumedua/cpp-toolchain/documentation-experimental)](https://hub.docker.com/repository/docker/guillaumedua/cpp-toolchain/tags) |
| `dev-` *(or no prefix)* | `dev` | Full **dev** environment: static analysis + docs + dynamic analysis, debug, editors, shells | [![size](https://img.shields.io/docker/image-size/guillaumedua/cpp-toolchain/dev-latest)](https://hub.docker.com/repository/docker/guillaumedua/cpp-toolchain/tags) | [![size](https://img.shields.io/docker/image-size/guillaumedua/cpp-toolchain/dev-experimental)](https://hub.docker.com/repository/docker/guillaumedua/cpp-toolchain/tags) |

Pulls: [![pulls](https://img.shields.io/docker/pulls/guillaumedua/cpp-toolchain)](https://hub.docker.com/repository/docker/guillaumedua/cpp-toolchain/general)

```bash
# build a specific stage locally (context is .devcontainer)
docker build --target runtime         -t cpp-toolchain:runtime         -f .devcontainer/Dockerfile .devcontainer
docker build --target build           -t cpp-toolchain:build           -f .devcontainer/Dockerfile .devcontainer
docker build --target static-analysis -t cpp-toolchain:static-analysis -f .devcontainer/Dockerfile .devcontainer
docker build --target documentation   -t cpp-toolchain:documentation   -f .devcontainer/Dockerfile .devcontainer
docker build --target dev             -t cpp-toolchain:dev             -f .devcontainer/Dockerfile .devcontainer
```

SSH remote access is an opt-in extra layer on top of `dev` — see [Remote access](#remote-access-opt-in) below.

### Registries & tags

Every stage is published to both registries, under the same `cpp-toolchain` name:

```bash
docker pull guillaumedua/cpp-toolchain:build-latest          # Docker Hub
docker pull ghcr.io/guillaumedua/cpp-toolchain:build-latest  # GitHub Container Registry
```

Prefer **GHCR** when pulling from CI: public GHCR images have no pull rate limit, whereas Docker Hub throttles anonymous pulls per IP.

A tag is `<stage>-<version>`: the **stage** picks *what is in the image* (see the table above), the **version** picks *how fresh it is*.

| Version | Published by | Meaning |
| ------- | ------------ | ------- |
| `v<major>.<minor>` (e.g. `build-v1.0`) | a GitHub **release**, cut from `main` | A specific **release**, pinned and immutable; the version matches the release tag exactly |
| `latest` (e.g. `build-latest`) | the same release | Newest **release** - what you want unless you know otherwise |
| `experimental` (e.g. `build-experimental`) | the **weekly** schedule (Saturday 4am UTC), from `main` | Newest **build** of `main`: *ahead of* `latest`, unreleased. Rebuilt against current upstream (toolchain PPA, apt.llvm.org, Kitware), so it may break - never aliased to `latest` |

Note that `latest` tracks **releases, not recency**: `experimental` is always the more recent build of the two. Pin `<stage>-v<major>.<minor>` for reproducible builds, use `<stage>-latest` for the current release, and reach for `<stage>-experimental` only when you want the freshest toolchain between releases and can tolerate breakage.

`dev` is the Dockerfile's default target, so it also answers to the **unprefixed** versions - `cpp-toolchain:latest` is the same digest as `cpp-toolchain:dev-latest`, and likewise for `v1.0` / `experimental`. Every other stage must be named explicitly.

> [!NOTE]
> These images previously lived in a separate `guillaumedua/cpp-toolchain-dev` repository, which is **deprecated and frozen** (Docker Hub repositories cannot be renamed). Replace `cpp-toolchain-dev:<version>` with `cpp-toolchain:dev-<version>`.

Every PR to `main` must still build all five images ([docker-build](.github/workflows/docker-build.yml)); publishing is a separate workflow that refuses to push anything whose commit is not contained in `main`.

---

## Features

### Packages

Presence per published image. It's a diamond: `static-analysis` and `documentation` both build on `build`; `dev` combines them.

| Category                                                                                                    | `runtime` | `build` | `static-analysis` | `documentation` | `dev` |
| ----------------------------------------------------------------------------------------------------------- | :-------: | :-----: | :---------------: | :-------------: | :---: |
| C++ runtime libraries (`libc6`, `libgcc-s1`, `libstdc++6`)                                                  |    ✅     |   ✅    |        ✅         |       ✅        |  ✅   |
| Compilers: GNU-G++, LLVM-Clang++                                                                            |           |   ✅    |        ✅         |       ✅        |  ✅   |
| Cross-compilation: cross-binutils + cross-glibc (see [Cross-architecture](#cross-architecture-compilation)) |           |   ✅    |        ✅         |       ✅        |  ✅   |
| Multilib: secondary ABIs `-m32` / `-mx32`                                                                   |           |   ✅    |        ✅         |       ✅        |  ✅   |
| Build systems: CMake, make/Unix-makefile, ninja, ccache (+ opt-in Bazel, Build2)                            |           |   ✅    |        ✅         |       ✅        |  ✅   |
| Dependency management: vcpkg, conan (python3)                                                               |           |   ✅    |        ✅         |       ✅        |  ✅   |
| Versioning: git                                                                                             |           |   ✅    |        ✅         |       ✅        |  ✅   |
| Coverage (GNU): gcov, gcov-tool                                                                             |           |   ✅    |        ✅         |       ✅        |  ✅   |
| Coverage (LLVM): llvm-cov, llvm-profdata                                                                    |           |         |        ✅         |       ✅        |  ✅   |
| Static analysis: clang-tidy, clang-format, clangd, scan-build, cppcheck, iwyu (+ lldb)                      |           |         |        ✅         |                 |  ✅   |
| Documentation: doxygen, graphviz - and coverage reports: lcov / genhtml                                     |           |         |                   |       ✅        |  ✅   |
| Dynamic analysis / debug: valgrind, gdb                                                                     |           |         |                   |                 |  ✅   |
| Versioning extra: subversion                                                                                |           |         |                   |                 |  ✅   |
| Editors: emacs, nano, vim                                                                                   |           |         |                   |                 |  ✅   |
| Shells: bash, zsh                                                                                           |           |         |                   |                 |  ✅   |
| Misc: jq, ripgrep, docker-compose                                                                           |           |         |                   |                 |  ✅   |

The `build` stage installs Clang/LLVM minimalistically (just `clang`/`clang++`); the full LLVM tooling (`clang-tidy`, `clang-format`, `clangd`, `lldb`, `scan-build`, ...) is wired up in the `static-analysis` stage (and inherited by `dev`). `valgrind` (dynamic analysis) lives in `dev`.

### Arguments

| Name                    | default           | description                                                                            | example                                  |
| ----------------------- | ----------------- | -------------------------------------------------------------------------------------- | ---------------------------------------- |
| CMAKE_VERSION           | `latest`          | `latest`<br>(exact version, e.g. `3.29.3-0kitware1ubuntu24.04.1~jammy`)                | `latest`                                 |
| GCC_VERSIONS            | `'latest-stable'` | `all`<br>`latest`<br>`latest-stable`<br>`>=(number)`<br>`(space-separated-numbers...)` | `all`<br>`latest`<br>`>=13`<br>`9 11 13` |
| LLVM_VERSIONS           | `'latest-stable'` | `all`<br>`latest`<br>`latest-stable`<br>`>=(number)`<br>`(space-separated-numbers...)` | `all`<br>`latest`<br>`>=13`<br>`11 13`   |
| BINUTILS_TARGETS        | `'aarch64-linux-gnu powerpc64-linux-gnu'` | GNU target triplets to install cross-binutils + cross-glibc for (space-separated) - see [Cross-architecture](#cross-architecture-compilation) | `'riscv64-linux-gnu arm-linux-gnueabihf'` |
| OPT_IN_INTEGRATE_BAZEL  | `n`               | `y` or `n`                                                                             |                                          |
| OPT_IN_INTEGRATE_BUILD2 | `n`               | `y` or `n`                                                                             |                                          |

The published image installs a single `latest-stable` for `GCC` and `Clang/LLVM` by default, to keep the image lean.  
`gcc.sh` and `llvm.sh` both support installing **multiple versions side by side** (via `update-alternatives`), which is useful when you need to test against several compiler versions in the same environment. To get that in your own build, override the version args, e.g.:

```bash
docker build -t cpp-toolchain:dev -f .devcontainer/Dockerfile .devcontainer \
    --build-arg GCC_VERSIONS='>=13' \
    --build-arg LLVM_VERSIONS='12 20 22'
```

See [.devcontainer/scripts/README.md](.devcontainer/scripts/README.md) for the full `cmake.sh` / `gcc.sh` / `llvm.sh` / `binutils.sh` options (also usable standalone on any Debian/Ubuntu-based system).

### Remote access (opt-in)

The published image does **not** ship an SSH server by default.  
Remote/SSH access is an opt-in extra layer, built on top of the base image via [`.devcontainer/ssh_support.dockerfile`](.devcontainer/ssh_support.dockerfile):

```bash
# from the .devcontainer/ directory
docker build --target dev -t cpp-toolchain:dev -f Dockerfile .
docker compose --profile ssh build ssh_support
docker compose --profile ssh run --service-ports ssh_support
```

This creates a `vscodeuser` (password `password`) with sudo rights, and exposes SSH on port `2222`.

---

## Compiling C++

Everything in this section is available from the **`build`** stage onwards, and therefore also in `static-analysis`, `documentation` and `dev`.

### Compilers & versions

Both toolchains are installed side by side - `latest-stable` of each by default:

| Toolchain | Command             | Versioned command           | Also registered                                                  |
| --------- | ------------------- | --------------------------- | ---------------------------------------------------------------- |
| GNU       | `gcc` / `g++`       | `gcc-<N>` / `g++-<N>`       | `gcov`, `gcov-tool`                                              |
| LLVM      | `clang` / `clang++` | `clang-<N>` / `clang++-<N>` | `clang-tidy`, `clangd`, `lldb`, ... in `static-analysis` / `dev` |

Unversioned commands are `update-alternatives` symlinks; the **latest-stable version always has the highest priority**. Install several versions side by side via the `GCC_VERSIONS` / `LLVM_VERSIONS` build args (see [Arguments](#arguments)), then either switch the default or call a versioned binary directly:

```bash
update-alternatives --config gcc      # switch the default gcc/g++/gcov/gcov-tool set
update-alternatives --config clang    # switch the default clang/clang++ set

g++-14     -std=c++23 main.cpp        # or pin explicitly
clang++-20 -std=c++23 main.cpp
```

The installed versions are also exported as `gcc_versions` / `llvm_versions` shell variables (bash & zsh).

### Standard library

| Compiler  | Default standard library                | Alternative      |
| --------- | --------------------------------------- | ---------------- |
| `g++`     | `libstdc++`                             | -                |
| `clang++` | `libstdc++` (GCC's - the Linux default) | `-stdlib=libc++` |

libc++ (`libc++-<N>-dev`, `libc++abi-<N>-dev`, `libunwind-<N>-dev`) is installed for the **host** architecture, so the LLVM toolchain is fully usable *without* GCC:

```bash
clang++ -std=c++23 -stdlib=libc++ main.cpp
```

### Cross-architecture compilation

The image ships cross **binutils** (target `as` / `ld` / `objdump` / ...) plus the matching cross **glibc**, installed by [`binutils.sh`](.devcontainer/scripts/binutils.sh). Defaults:

| Target triplet        | Debian arch | Packages                                                 |
| --------------------- | ----------- | -------------------------------------------------------- |
| `aarch64-linux-gnu`   | `arm64`     | `binutils-aarch64-linux-gnu` + `libc6-dev-arm64-cross`   |
| `powerpc64-linux-gnu` | `ppc64`     | `binutils-powerpc64-linux-gnu` + `libc6-dev-ppc64-cross` |

Pick your own targets at build time, or standalone:

```bash
docker build --target build -t cpp-toolchain:build -f .devcontainer/Dockerfile .devcontainer \
    --build-arg BINUTILS_TARGETS='aarch64-linux-gnu riscv64-linux-gnu arm-linux-gnueabihf'
```

```bash
sudo ./binutils.sh --list                                     # target triplets available on this host
sudo ./binutils.sh --targets='riscv64-linux-gnu s390x-linux-gnu'
```

**CPU, FPU and ABI variants are selected by the triplet itself** - there is no separate switch:

| Axis       | Example triplets                                                           |
| ---------- | -------------------------------------------------------------------------- |
| FPU        | `arm-linux-gnueabi` (soft-float) vs `arm-linux-gnueabihf` (hard-float VFP) |
| ABI        | `mips64-linux-gnuabi64` (n64) vs `mips64-linux-gnuabin32` (n32)            |
| ABI        | `x86-64-linux-gnu` (LP64) vs `x86-64-linux-gnux32` (x32)                   |
| CPU / ISA  | `mipsisa32r6-linux-gnu`, `mipsisa64r6el-linux-gnuabi64` (MIPS release 6)   |
| Endianness | `powerpc64` vs `powerpc64le`, `mips` vs `mipsel`                           |

29 target triplets map to a cross-glibc. `alpha-linux-gnu`, `hppa64-linux-gnu` and `ia64-linux-gnu` get cross-binutils **only** - no cross-libc is published for them, which the script logs and skips.

#### What works, and what does not

| Capability                                     | Status                                                         |
| ---------------------------------------------- | -------------------------------------------------------------- |
| Cross-compile **C**                            | ✅ cross binutils + cross glibc                                |
| Cross-**link**, inspect / strip target objects | ✅                                                             |
| Cross-compile **C++**                          | ⚠️ requires a *target* C++ standard library, **not bundled** |

```bash
clang --target=aarch64-linux-gnu   main.c     # ✅ works
clang++ --target=aarch64-linux-gnu main.cpp   # ⚠️ fails: no target C++ stdlib
```

To cross-compile C++ you need a C++ standard library built **for the target**:

- **libstdc++** - obtainable per target via `g++-<triplet>` or `libstdc++-<N>-dev-<debarch>-cross`.
- **libc++** - no portable apt cross package exists; it requires an LLVM `runtimes` source build. Note this affects the *cross* case only: the **host** libc++ is installed, so native `clang++ -stdlib=libc++` works (see [Standard library](#standard-library)).

### Multilib - secondary ABIs

Distinct from cross-compilation: multilib is the *same* GCC emitting a **secondary ABI of the host architecture**, via `gcc-<N>-multilib` / `g++-<N>-multilib` (which pull `libc6-dev-i386`, `libc6-dev-x32`, `lib32stdc++-<N>-dev`, ...).

```bash
g++ -m64  main.cpp   # native LP64 (default)
g++ -m32  main.cpp   # 32-bit x86 (i386)
g++ -mx32 main.cpp   # x32 - 32-bit pointers, 64-bit registers
```

Installed by default, **best-effort**: multilib lags for brand-new GCC versions and does not exist on non-amd64 hosts, so an unavailable package is skipped with a log rather than failing the build. `gcc.sh` exposes `--multilib` (default on) and `-m` / `--minimalistic` (compilers only); an *explicit* `--multilib=yes` is honored strictly and fails hard if unavailable.

### Code coverage

Both ecosystems are supported. They are **not** interchangeable: `gcov`/`lcov` read GCC counters (`.gcno` / `.gcda`), `llvm-cov`/`llvm-profdata` read Clang's (`.profraw` / `.profdata`).

| Tool                        | Toolchain |     `build`      | `static-analysis` | `documentation` | `dev` |
| --------------------------- | --------- | :--------------: | :---------------: | :-------------: | :---: |
| `gcov`, `gcov-tool`         | GNU       |        ✅        |        ✅         |       ✅        |  ✅   |
| `lcov`, `genhtml`           | GNU       |                  |                   |       ✅        |  ✅   |
| `llvm-cov`, `llvm-profdata` | LLVM      | *versioned only* |        ✅         |       ✅        |  ✅   |

```bash
# GNU: gcov counters -> lcov/genhtml HTML report
g++ --coverage main.cpp -o app && ./app
lcov --capture --directory . --output-file cov.info && genhtml cov.info --output-directory html

# LLVM: instrumented profile -> llvm-profdata -> llvm-cov
clang++ -fprofile-instr-generate -fcoverage-mapping main.cpp -o app
LLVM_PROFILE_FILE=app.profraw ./app
llvm-profdata merge -sparse app.profraw -o app.profdata
llvm-cov show ./app -instr-profile=app.profdata
```

In `build`, Clang is installed minimalistically, so only the versioned `llvm-cov-<N>` / `llvm-profdata-<N>` exist there; the unversioned commands are registered from `static-analysis` / `documentation` onwards. `lcov` (the Perl frontend producing HTML) ships in the coverage-oriented stages only - `gcov` itself always comes with GCC.

> [!TIP]
> `llvm-cov` can also read GCC-style counters via its `llvm-cov gcov` compatibility mode, so `lcov --gcov-tool "llvm-cov gcov"` bridges Clang-compiled coverage into an `lcov` report.

---

## Usage

### vscode - "Reopen in container"

Make sure to meet the following requirements:

- a `devcontainer.json` file. See [this example](.devcontainer/devcontainer.json).
- which references a `docker-compose.yaml` file. See [this example](.devcontainer/docker-compose.yaml).

### vscode - "Remote SSH"

In `vscode`, using `Remote SSH` extension, after starting the opt-in `ssh_support` service (see [Remote access](#remote-access-opt-in) above):

- Connect window to host

With a `.ssh/config` (forwards port `2222:22`) like:

```config
Host localhost
  HostName localhost
  User vscodeuser
  Password password
  ForwardAgent yes
  Port 2222
```

with password "password"

## Dependency updates

Base image, GitHub Actions, and `zsh-in-docker` version bumps are tracked via [Renovate](renovate.json), scheduled weekly.
