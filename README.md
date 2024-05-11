# cpp-toolchain

Up-to-date C++ toolchain docker for development.

Available here on [DockerHub](https://hub.docker.com/repository/docker/guillaumedua/cpp-toolchain-dev/general).

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

| Name                    | default  | description                                                         | example                                  |
| ----------------------- | -------- | ------------------------------------------------------------------- | ---------------------------------------- |
| GCC_VERSIONS            | `'>=11'` | `all`<br>`latest`<br>`>=(number)`<br>`(space-separated-numbers...)` | `all`<br>`latest`<br>`>=13`<br>`9 11 13` |
| LLVM_VERSIONS           | `'>=14'` | `all`<br>`latest`<br>`>=(number)`<br>`(space-separated-numbers...)` | `all`<br>`latest`<br>`>=13`<br>`11 13`   |
| OPT_IN_INTEGRATE_BAZEL  | `n`      | `y` or `n`                                                   |                                          |
| OPT_IN_INTEGRATE_BUILD2 | `n`      | `y` or `n`                                                   |                                          |

### Misc

Remote access using ssh (openssh-server, rsync) on port 22

## Usage

### vscode - "Reopen in container"

Make sure to meet the following requirements:

- a `devcontainer.json` file. See [this example](./.devcontainer/devcontainer.json).
- which make reference a `docker-compose.yml` file. See [this example](./.devcontainer/docker-compose.yaml).

### vscode - "Remote SSH"

In `vscode`, using `Remote SSH` extension:

- Connect window to host

With a `.ssh/config` with a (docker-compose which forwards port `2222:22`) like:

```config
Host localhost
  HostName localhost
  User vscodeuser
  Password password
  ForwardAgent yes
  Port 2222
```

with password "password"
