# cpp-toolchain

Up-to-date C++ toolchain docker for development.

[![docker-publish](https://github.com/GuillaumeDua/cpp-toolchain/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/GuillaumeDua/cpp-toolchain/actions/workflows/docker-publish.yml)
[![Docker Pulls](https://img.shields.io/docker/pulls/guillaumedua/cpp-toolchain-dev)](https://hub.docker.com/repository/docker/guillaumedua/cpp-toolchain-dev/general)
[![Docker Image Size](https://img.shields.io/docker/image-size/guillaumedua/cpp-toolchain-dev/latest)](https://hub.docker.com/repository/docker/guillaumedua/cpp-toolchain-dev/general)

Available here on [DockerHub](https://hub.docker.com/repository/docker/guillaumedua/cpp-toolchain-dev/general). Rebuilt weekly (and on every change) via [GitHub Actions](.github/workflows/docker-publish.yml).

---

## Features

### Packages

- Compilers: GNU-G++, LLVM-Clang++
- Build: CMake Bazel Build2 make/Unix-makefile ninja ccache
- Dependency-management: vcpkg conan
- Analysis: valgrind cppcheck iwyu
- Versioning: git subversion
- Debug: gdb lldb
- Documentation: doxygen graphviz
- Shells: bash zsh
- Tools: python3, jq, ripgrep

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
docker build -t cpp-toolchain-dev -f Dockerfile .
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
