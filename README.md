# cpp-toolchain

Up-to-date C++ toolchain docker images for development, built as a multi-stage [`Dockerfile`](.devcontainer/Dockerfile) and published as three DockerHub repositories.

[![docker-publish](https://github.com/GuillaumeDua/cpp-toolchain/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/GuillaumeDua/cpp-toolchain/actions/workflows/docker-publish.yml)

Rebuilt weekly (and on every change) via [GitHub Actions](.github/workflows/docker-publish.yml).

## Images

The [Dockerfile](.devcontainer/Dockerfile) is a superset chain (`dev` ⊃ `build` ⊃ `runtime`); each stage is published as its own image and can be selected locally with `docker build --target <stage>` (omitting `--target` builds `dev`, the last stage):

| Image | `--target` | Purpose | Size |
| ----- | ---------- | ------- | ---- |
| [`cpp-toolchain-runtime`](https://hub.docker.com/repository/docker/guillaumedua/cpp-toolchain-runtime/general) | `runtime` | Minimal C++ runtime (`libc`/`libstdc++`) to **run** compiled binaries | [![size](https://img.shields.io/docker/image-size/guillaumedua/cpp-toolchain-runtime/latest)](https://hub.docker.com/repository/docker/guillaumedua/cpp-toolchain-runtime/general) |
| [`cpp-toolchain-build`](https://hub.docker.com/repository/docker/guillaumedua/cpp-toolchain-build/general) | `build` | **Compile** C++: compilers, build systems, dependency managers (CI) | [![size](https://img.shields.io/docker/image-size/guillaumedua/cpp-toolchain-build/latest)](https://hub.docker.com/repository/docker/guillaumedua/cpp-toolchain-build/general) |
| [`cpp-toolchain-dev`](https://hub.docker.com/repository/docker/guillaumedua/cpp-toolchain-dev/general) | `dev` | Full **dev** environment: `build` + static analysis, debug, docs, editors, shells | [![size](https://img.shields.io/docker/image-size/guillaumedua/cpp-toolchain-dev/latest)](https://hub.docker.com/repository/docker/guillaumedua/cpp-toolchain-dev/general) |

Pulls: [![runtime](https://img.shields.io/docker/pulls/guillaumedua/cpp-toolchain-runtime?label=runtime)](https://hub.docker.com/repository/docker/guillaumedua/cpp-toolchain-runtime/general) [![build](https://img.shields.io/docker/pulls/guillaumedua/cpp-toolchain-build?label=build)](https://hub.docker.com/repository/docker/guillaumedua/cpp-toolchain-build/general) [![dev](https://img.shields.io/docker/pulls/guillaumedua/cpp-toolchain-dev?label=dev)](https://hub.docker.com/repository/docker/guillaumedua/cpp-toolchain-dev/general)

```bash
# build a specific stage locally (context is .devcontainer)
docker build --target runtime -t cpp-toolchain-runtime -f .devcontainer/Dockerfile .devcontainer
docker build --target build   -t cpp-toolchain-build   -f .devcontainer/Dockerfile .devcontainer
docker build --target dev      -t cpp-toolchain-dev     -f .devcontainer/Dockerfile .devcontainer
```

SSH remote access is an opt-in extra layer on top of `dev` — see [Remote access](#remote-access-opt-in) below.

---

## Features

### Packages

Packages are distributed across the stages; each column is a superset of the one to its left.

| Category                                                                         | `runtime` | `build` | `dev` |
| -------------------------------------------------------------------------------- | :-------: | :-----: | :---: |
| C++ runtime libraries (`libc6`, `libgcc-s1`, `libstdc++6`)                       |    ✅     |   ✅    |  ✅   |
| Compilers: GNU-G++, LLVM-Clang++                                                 |           |   ✅    |  ✅   |
| Build systems: CMake, make/Unix-makefile, ninja, ccache (+ opt-in Bazel, Build2) |           |   ✅    |  ✅   |
| Dependency management: vcpkg, conan (python3)                                    |           |   ✅    |  ✅   |
| Versioning: git                                                                  |           |   ✅    |  ✅   |
| Static analysis: valgrind, cppcheck, iwyu, clang-tidy, clang-format, scan-build  |           |         |  ✅   |
| Debug: gdb, lldb                                                                 |           |         |  ✅   |
| Documentation: doxygen, graphviz                                                 |           |         |  ✅   |
| Editors: emacs, nano, vim                                                        |           |         |  ✅   |
| Shells: bash, zsh                                                                |           |         |  ✅   |
| Misc: jq, ripgrep                                                                |           |         |  ✅   |

The `build` stage installs Clang/LLVM minimalistically (just `clang`/`clang++`); the full LLVM tooling (`clang-tidy`, `clang-format`, `clangd`, `lldb`, `scan-build`, ...) is a static-analysis concern wired up in `dev`.

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
docker build -t cpp-toolchain-dev -f .devcontainer/Dockerfile .devcontainer \
    --build-arg GCC_VERSIONS='>=13' \
    --build-arg LLVM_VERSIONS='12 20 22'
```

See [.devcontainer/scripts/README.md](.devcontainer/scripts/README.md) for the full `cmake.sh` / `gcc.sh` / `llvm.sh` options (also usable standalone on any Debian/Ubuntu-based system).

### Remote access (opt-in)

The published image does **not** ship an SSH server by default. Remote/SSH access is an opt-in extra layer, built on top of the base image via [`.devcontainer/ssh_support.dockerfile`](.devcontainer/ssh_support.dockerfile):

```bash
# from the .devcontainer/ directory
docker build --target dev -t cpp-toolchain-dev -f Dockerfile .
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
