# Using cpp-toolchain as a dev environment

The `dev` stage is a complete C++ development environment (compilers, static/dynamic analysis, docs, debuggers, editors, shells).

This guide covers the two ways to work inside it from [VS Code](https://code.visualstudio.com/):

- [Reopen in Container](#reopen-in-container) - the dev container workflow (recommended)
- [Remote SSH](#remote-ssh) - the opt-in SSH server, for remote or detached hosts

Both also work from any editor that speaks the Dev Containers or SSH protocols; the steps below are written for `VS Code`.

## Reopen in Container

VS Code opens the repository directly inside a `dev` container. You need two files:

- a [`devcontainer.json`](../.devcontainer/devcontainer.json) - see the example in this repo,
- which references a [`docker-compose.yaml`](../.devcontainer/docker-compose.yaml) - likewise.

With both present, run **Dev Containers: Reopen in Container** from the VS Code command palette. The container is pulled from the image referenced in `docker-compose.yaml`, so no local build is required.

## Remote SSH

The published image does **not** ship an SSH server by default. Remote/SSH access is an opt-in extra layer, built on top of `dev` via [`.devcontainer/ssh_support.dockerfile`](../.devcontainer/ssh_support.dockerfile).

### 1. Build and start the SSH service

```bash
# from the .devcontainer/ directory
docker build --target dev -t cpp-toolchain:dev -f Dockerfile .
docker compose --profile ssh build ssh_support
docker compose --profile ssh run --service-ports ssh_support
```

This creates a `vscodeuser` (password `password`) with sudo rights, and exposes SSH on port `2222`.

### 2. Connect from VS Code

With the **Remote - SSH** extension, add a host to your `~/.ssh/config` (forwarding `2222` -> `22`):

```ssh-config
Host cpp-toolchain
  HostName localhost
  User vscodeuser
  Port 2222
  ForwardAgent yes
```

Then run **Remote-SSH: Connect to Host...** -> `cpp-toolchain` and enter the password `password` when prompted.

> [!WARNING]
> The default `vscodeuser` / `password` credentials are for local development only. Change them before exposing port `2222` beyond `localhost`.

## See also

- [README.md](../README.md) - images, features, build arguments, cross-architecture compilation.
- [Images](../README.md#images) - the five stages and what each contains.
