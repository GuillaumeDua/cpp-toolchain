# cpp-toolchain

Up-to-date C++ toolchain docker images for development, built as a multi-stage [`Dockerfile`](.devcontainer/Dockerfile) and published as five stages on:

- [DockerHub repository](https://hub.docker.com/repository/docker/guillaumedua/cpp-toolchain)
- GHRC *(TODO: link will be added here later when 1.0 is published)*

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

| Category                                                                               | `runtime` | `build` | `static-analysis` | `documentation` | `dev` |
| -------------------------------------------------------------------------------------- | :-------: | :-----: | :---------------: | :-------------: | :---: |
| C++ runtime libraries (`libc6`, `libgcc-s1`, `libstdc++6`)                             |    ✅     |   ✅    |        ✅         |       ✅        |  ✅   |
| Compilers: GNU-G++, LLVM-Clang++                                                       |           |   ✅    |        ✅         |       ✅        |  ✅   |
| Build systems: CMake, make/Unix-makefile, ninja, ccache (+ opt-in Bazel, Build2)       |           |   ✅    |        ✅         |       ✅        |  ✅   |
| Dependency management: vcpkg, conan (python3)                                          |           |   ✅    |        ✅         |       ✅        |  ✅   |
| Versioning: git                                                                        |           |   ✅    |        ✅         |       ✅        |  ✅   |
| Static analysis: clang-tidy, clang-format, clangd, scan-build, cppcheck, iwyu (+ lldb) |           |         |        ✅         |                 |  ✅   |
| Documentation: doxygen, graphviz                                                       |           |         |                   |       ✅        |  ✅   |
| Dynamic analysis / debug: valgrind, gdb                                                |           |         |                   |                 |  ✅   |
| Versioning extra: subversion                                                           |           |         |                   |                 |  ✅   |
| Editors: emacs, nano, vim                                                              |           |         |                   |                 |  ✅   |
| Shells: bash, zsh                                                                      |           |         |                   |                 |  ✅   |
| Misc: jq, ripgrep, docker-compose                                                      |           |         |                   |                 |  ✅   |

The `build` stage installs Clang/LLVM minimalistically (just `clang`/`clang++`); the full LLVM tooling (`clang-tidy`, `clang-format`, `clangd`, `lldb`, `scan-build`, ...) is wired up in the `static-analysis` stage (and inherited by `dev`). `valgrind` (dynamic analysis) lives in `dev`.

### Arguments

| Name                    | default           | description                                                                            | example                                  |
| ----------------------- | ----------------- | -------------------------------------------------------------------------------------- | ---------------------------------------- |
| CMAKE_VERSION           | `latest`          | `latest`<br>(exact version, e.g. `3.29.3-0kitware1ubuntu24.04.1~jammy`)                | `latest`                                 |
| GCC_VERSIONS            | `'latest-stable'` | `all`<br>`latest`<br>`latest-stable`<br>`>=(number)`<br>`(space-separated-numbers...)` | `all`<br>`latest`<br>`>=13`<br>`9 11 13` |
| LLVM_VERSIONS           | `'latest-stable'` | `all`<br>`latest`<br>`latest-stable`<br>`>=(number)`<br>`(space-separated-numbers...)` | `all`<br>`latest`<br>`>=13`<br>`11 13`   |
| OPT_IN_INTEGRATE_BAZEL  | `n`               | `y` or `n`                                                                             |                                          |
| OPT_IN_INTEGRATE_BUILD2 | `n`               | `y` or `n`                                                                             |                                          |

The published image installs a single `latest-stable` for `GCC` and `Clang/LLVM` by default, to keep the image lean.  
`gcc.sh` and `llvm.sh` both support installing **multiple versions side by side** (via `update-alternatives`), which is useful when you need to test against several compiler versions in the same environment. To get that in your own build, override the version args, e.g.:

```bash
docker build -t cpp-toolchain:dev -f .devcontainer/Dockerfile .devcontainer \
    --build-arg GCC_VERSIONS='>=13' \
    --build-arg LLVM_VERSIONS='12 20 22'
```

See [.devcontainer/scripts/README.md](.devcontainer/scripts/README.md) for the full `cmake.sh` / `gcc.sh` / `llvm.sh` options (also usable standalone on any Debian/Ubuntu-based system).

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
