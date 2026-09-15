# Using the images

Every way to consume the published images, one section each.  
Using the toolchain **without** Docker is [scripts/README.md](../scripts/README.md) instead: the install scripts run standalone on any `Debian`/`Ubuntu` host.

Which stage to pull is [Pick your image](../README.md#pick-your-image-one-per-stage) - `dev` for an interactive environment, `build` for CI.  
Every example here uses `latest`; pin `v1.3` instead when the tag has to stay put, per [Tags & versioning](../README.md#tags--versioning).  
Both registries carry the same images, so `docker.io/guillaumedua/cpp-toolchain` substitutes for `ghcr.io/guillaumedua/cpp-toolchain` throughout.

> [!WARNING]
> **Everything runs as root**
>
> No stage declares a `USER`, and no non-root account exists in the image - the opt-in [SSH layer](#remote-ssh) is the only thing that creates one.  
> A build run over a bind mount therefore leaves root-owned files on your host.
> `--user "$(id -u):$(id -g)"` corrects the ownership, at the cost of a uid with no `/etc/passwd` entry.

## Pull an image

```bash
# Full dev environment: compilers + analysis + docs + debug, editors, shells
docker pull ghcr.io/guillaumedua/cpp-toolchain:dev-latest

# Lean CI image: compilers + build systems + dependency managers
docker pull ghcr.io/guillaumedua/cpp-toolchain:build-latest
```

Prefer [GHCR](https://github.com/GuillaumeDua/cpp-toolchain/pkgs/container/cpp-toolchain) for CI: public images there have no anonymous pull rate limit.

## One-off container

```bash
# Check what you pulled
docker run --rm ghcr.io/guillaumedua/cpp-toolchain:build-latest g++ --version

# Compile the working directory
docker run --rm --volume "${PWD}:/src" --workdir /src \
    ghcr.io/guillaumedua/cpp-toolchain:build-latest \
    g++ -std=c++23 main.cpp -o main
```

## Visual Studio Code - Dev container

Put a `.devcontainer/devcontainer.json` in **your** `vscode` project - the image reference is the whole file:

```json
{
    "name": "my-project",
    "image": "ghcr.io/guillaumedua/cpp-toolchain:dev-latest"
}
```

Then run **Dev Containers: Reopen in Container** from the VS Code command palette.
Nothing is built: the image is pulled, and your project is mounted into it.

Anything else is optional - `features` to add tooling, `customizations.vscode.extensions` to preinstall extensions.

## GitHub Actions

A job's `container:` key runs every `run:` step inside the image, so the toolchain needs no setup action.  
Each job below takes the leanest stage carrying what it needs, per [Pick your image](../README.md#pick-your-image-one-per-stage).

### Compile and test - `build`

```yaml
jobs:
  build:
    runs-on: ubuntu-24.04
    container: ghcr.io/guillaumedua/cpp-toolchain:build-latest
    steps:
      - uses: actions/checkout@v4
      - run: |
          cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
          cmake --build build
          ctest --test-dir build --output-on-failure
```

### Static analysis - `static-analysis`

`clang-tidy`, `clang-format`, `cppcheck`, `scan-build` and `iwyu` answer to unversioned names from this stage onwards, not from `build`.

```yaml
jobs:
  lint:
    runs-on: ubuntu-24.04
    container: ghcr.io/guillaumedua/cpp-toolchain:static-analysis-latest
    steps:
      - uses: actions/checkout@v4
      - run: |
          cmake -S . -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
          clang-tidy -p build src/*.cpp
          clang-format --dry-run --Werror src/*.cpp
```

### API documentation - `documentation`

`doxygen` here is a pinned upstream build rather than Ubuntu's apt package, which lags it, and `graphviz` ships beside it - so `HAVE_DOT = YES` renders call and collaboration graphs with nothing else to install.

```yaml
jobs:
  docs:
    runs-on: ubuntu-24.04
    container: ghcr.io/guillaumedua/cpp-toolchain:documentation-latest
    steps:
      - uses: actions/checkout@v4
      - run: doxygen Doxyfile
      - uses: actions/upload-artifact@v4
        with:
          name: api-docs
          path: html
```

`html` is doxygen's default `HTML_OUTPUT`; point the upload at whatever your `Doxyfile` sets.

### Coverage report - `documentation`

`lcov` and `genhtml` ship in this stage only - `gcov` itself comes with GCC everywhere, so a stage below this one produces counters but no HTML.
Which tool lives where is [Code coverage](COVERAGE.md).

```yaml
jobs:
  coverage:
    runs-on: ubuntu-24.04
    container: ghcr.io/guillaumedua/cpp-toolchain:documentation-latest
    steps:
      - uses: actions/checkout@v4
      - run: |
          cmake -S . -B build -DCMAKE_CXX_FLAGS=--coverage
          cmake --build build
          ctest --test-dir build
          lcov --capture --directory build --output-file cov.info
          genhtml cov.info --output-directory coverage-html
      - uses: actions/upload-artifact@v4
        with:
          name: coverage-html
          path: coverage-html
```

### Cross-compilation - `build-cross`

The `-cross` images add a `g++-<triplet>` per published target, so a matrix picks the triplet and nothing else changes.

```yaml
jobs:
  cross:
    runs-on: ubuntu-24.04
    container: ghcr.io/guillaumedua/cpp-toolchain:build-cross-latest
    strategy:
      matrix:
        target: [aarch64-linux-gnu, arm-linux-gnueabihf, riscv64-linux-gnu]
    steps:
      - uses: actions/checkout@v4
      - run: |
          cmake -S . -B build \
              -DCMAKE_SYSTEM_NAME=Linux \
              -DCMAKE_CXX_COMPILER=${{ matrix.target }}-g++
          cmake --build build
```

`common` resolves to those three and the host triplet - see [Cross-compilation](CROSS-COMPILATION.md).

### Run without a toolchain - `runtime`

`runtime` carries the C++ shared libraries and no compiler, so running there proves the binary has no build-time dependency left.
It needs the binary as an artifact from the build job above.

```yaml
jobs:
  smoke:
    needs: build
    runs-on: ubuntu-24.04
    container: ghcr.io/guillaumedua/cpp-toolchain:runtime-latest
    steps:
      - uses: actions/download-artifact@v4
        with:
          name: app
      - run: |
          chmod +x ./app
          ./app
```

## GitLab CI

```yaml
build:
  image: ghcr.io/guillaumedua/cpp-toolchain:build-latest
  script:
    - cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
    - cmake --build build
```

## Docker Compose

A service in **your** project's `compose.yaml`, with the source mounted and the container left running:

```yaml
services:
  toolchain:
    image: ghcr.io/guillaumedua/cpp-toolchain:dev-latest
    volumes:
      - .:/workspace
    working_dir: /workspace
    command: sleep infinity
    # ptrace-based debuggers - gdb, valgrind
    cap_add: [SYS_PTRACE]
    security_opt: [seccomp:unconfined]
```

`docker compose up -d` starts it, `docker compose exec toolchain bash` drops you in.

## Remote SSH

The published images ship **no SSH server**.
Remote access is an opt-in layer on top of `dev`, and it is a single Dockerfile that needs no clone:

```bash
wget https://raw.githubusercontent.com/GuillaumeDua/cpp-toolchain/main/.devcontainer/ssh_support.dockerfile

docker build --file ssh_support.dockerfile --tag cpp-toolchain:ssh \
    --build-arg BASE_IMAGE=ghcr.io/guillaumedua/cpp-toolchain:dev-latest \
    --build-arg USER_NAME=vscodeuser \
    --build-arg USER_PASSWORD=password \
    .

docker run --rm --publish 2222:22 --volume "${PWD}:/workspace" cpp-toolchain:ssh
```

That creates `vscodeuser` with sudo rights and exposes SSH on `2222`.
Add a host to `~/.ssh/config`:

```ssh-config
Host cpp-toolchain
  HostName localhost
  User vscodeuser
  Port 2222
  ForwardAgent yes
```

With the **Remote - SSH** extension, run **Remote-SSH: Connect to Host...** -> `cpp-toolchain`.

> [!WARNING]
> `USER_NAME` / `USER_PASSWORD` are passed as build arguments and land in the image history.
> Use throwaway credentials, and change them before exposing port `2222` beyond `localhost`.

## Build your own image

The published images carry a single pinned GCC and Clang/LLVM to stay lean.
Building from the repository gets you any other combination - the stage name is the `--target` argument, and omitting it builds `dev`:

```bash
git clone https://github.com/GuillaumeDua/cpp-toolchain.git
cd cpp-toolchain

# One stage, context is the repo root
docker build --target build -t cpp-toolchain:build .

# Several compiler versions side by side, wired through update-alternatives
docker build -t cpp-toolchain:dev . \
    --build-arg GCC_VERSIONS='>=13' \
    --build-arg LLVM_VERSIONS='12 20 22'
```

| Name | default | description | example |
| ---- | ------- | ----------- | ------- |
| CMAKE_VERSION | *pinned* | exact version, or `latest` | `latest` |
| GCC_VERSIONS | *pinned* | `all`<br>`latest`<br>`latest-stable`<br>`>=(number)`<br>`(space-separated-numbers...)` | `all`<br>`latest`<br>`>=13`<br>`9 11 13` |
| LLVM_VERSIONS | *pinned* | `all`<br>`latest`<br>`latest-stable`<br>`>=(number)`<br>`(space-separated-numbers...)` | `all`<br>`latest`<br>`>=13`<br>`11 13` |
| BINUTILS_TARGETS | `''` (none) | Cross toolchain target triplets; empty = lean, a list = cross-arch variant | `'aarch64-linux-gnu riscv64-linux-gnu'` |
| OPT_IN_INTEGRATE_BAZEL | `no` | `y` or `n` | |
| OPT_IN_INTEGRATE_BUILD2 | `no` | `y` or `n` | |

The *pinned* defaults are the `ARG` block at the top of the [Dockerfile](../Dockerfile), and every release note lists the values that release shipped.
`BINUTILS_TARGETS` on any `--target` build produces the cross-arch flavor of that stage - see [Cross-compilation](CROSS-COMPILATION.md).

## Choosing a compiler version

Unversioned commands are `update-alternatives` symlinks, and the latest-stable version always holds the highest priority.
With several versions installed, either switch the default or call a versioned binary:

```bash
update-alternatives --config gcc      # switch the default gcc/g++/gcov/gcov-tool set
update-alternatives --config clang    # switch the default clang/clang++ set

g++-14     -std=c++23 main.cpp        # or pin explicitly
clang++-20 -std=c++23 main.cpp
```

The installed versions are exported as `gcc_versions` / `llvm_versions` shell variables, in bash and zsh.

`clang++` defaults to GCC's `libstdc++`, the Linux default. libc++ is installed for the host architecture, so the LLVM toolchain is usable without GCC:

```bash
clang++ -std=c++23 -stdlib=libc++ main.cpp
```

## See also

- [README.md](../README.md) - the images themselves: stages, features, tags, what each contains.
- [scripts/README.md](../scripts/README.md) - the same toolchain without Docker, from standalone install scripts.
- [docs/CROSS-COMPILATION.md](CROSS-COMPILATION.md) - cross-architecture compilation and multilib.
- [docs/COVERAGE.md](COVERAGE.md) - the GNU and LLVM coverage tools, and which stage carries which.
