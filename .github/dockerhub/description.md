# cpp-toolchain

Up-to-date C++ toolchain images for the complete development cycle - **GNU and LLVM side by side**, from a minimal runtime to a full dev container.  
Built as a single multi-stage [`Dockerfile`](https://github.com/GuillaumeDua/cpp-toolchain/blob/main/Dockerfile), published here and to GHCR by GitHub Actions.

> - Source and full documentation: **[github.com/GuillaumeDua/cpp-toolchain](https://github.com/GuillaumeDua/cpp-toolchain)**, browsable as a [site](https://guillaumedua.github.io/cpp-toolchain)
> - Also on [ghcr.io/guillaumedua/cpp-toolchain](https://github.com/GuillaumeDua/cpp-toolchain/pkgs/container/cpp-toolchain), preferable in CI: public GHCR images have no pull rate limit.

Every Ubuntu release pins one GCC and one Clang version - 24.04 ships GCC 13 and Clang 18.
Getting past that means wiring up the toolchain repositories yourself, on every machine and in every CI job, then watching upstream for releases and bumping versions by hand.
These images carry both toolchains, a pinned major of each, so using GNU or LLVM - or moving between them later - is a matter of which command you run rather than which image you pull.

## Stages

Each stage is published as its own image, so you pull only what you need.

| Tag prefix | What's in it |
| ---------- | ------------ |
| `runtime-` | Minimal C++ **runtime** to run compiled binaries: `libc6`, `libgcc-s1`, `libstdc++6`, `libc++1`, `libc++abi1` |
| `build-` | **Compile** C++: GCC and Clang, CMake, make, ninja, ccache, vcpkg, conan, git, gcov |
| `static-analysis-` | `build` + **static analysis**: clang-tidy, clang-format, clangd, scan-build, cppcheck, iwyu, lldb, llvm-cov |
| `documentation-` | `build` + **documentation**: doxygen, graphviz - and coverage reports: lcov, genhtml |
| `dev-` *(or no prefix)* | Full **dev** environment: everything above, plus gdb, valgrind, editors, shells, jq, ripgrep |

`dev` is the Dockerfile's default target, so it also answers to the unprefixed versions: `cpp-toolchain:latest` is the same digest as `cpp-toolchain:dev-latest`.
Every other stage must be named explicitly.

## Tags

A tag is `<stage>[-cross]-<version>`: the **stage** picks what is in the image, the optional **`cross`** picks the cross-architecture flavor, and the **version** picks how fresh it is.

| Version | Published by | Meaning |
| ------- | ------------ | ------- |
| `v<major>.<minor>` (e.g. `build-v1.4`) | a GitHub **release** | A specific release, pinned and immutable |
| `latest` (e.g. `build-latest`) | the newest release | Newest **release** - what you want unless you know otherwise |
| `v<major>.<minor>-rc.<n>` (e.g. `build-v1.4-rc.2`) | the **twice-monthly rc schedule**, from `main` | A **release candidate** for the next minor: *ahead of* `latest`, rebuilt against current upstream, so breakage surfaces before it reaches a release. Never aliased to `latest` |

`latest` tracks **releases, not recency**: the newest rc is always the more recent build of the two.
Pin `<stage>-v<major>.<minor>` for reproducible builds.

A minor release is its rc's digests re-tagged rather than a rebuild, so `v1.4` is byte-identical to the `v1.4-rc.<n>` it was promoted from.
[Tags & versioning](https://github.com/GuillaumeDua/cpp-toolchain#tags--versioning) has the whole scheme, including what a pin does and does not fix.

```bash
docker pull guillaumedua/cpp-toolchain:build-latest        # compile in CI
docker pull guillaumedua/cpp-toolchain:runtime-v1.4        # ship a binary, pinned
docker pull guillaumedua/cpp-toolchain:latest              # full dev env (== dev-latest)
docker pull guillaumedua/cpp-toolchain:build-cross-latest  # cross-compile to arm64, arm32, riscv64
```

## Cross-architecture compilation

Every stage has a `-cross` variant, which compiles *and* links for `arm64`, `arm32` hard-float and `riscv64` - any supported triplet in a custom build: [Cross-compilation](https://github.com/GuillaumeDua/cpp-toolchain/blob/main/docs/CROSS-COMPILATION.md).
The published images are themselves `linux/amd64`, so on an `arm64` host they run under emulation.

## Running them

Dev container, GitHub Actions, GitLab CI, Compose, one-off `docker run`, Remote SSH, building your own variant: [Using the images](https://github.com/GuillaumeDua/cpp-toolchain/blob/main/docs/IMAGES.md).

The same toolchain without Docker: the [standalone scripts](https://github.com/GuillaumeDua/cpp-toolchain/blob/main/scripts/README.md) are published as release assets and run on any Debian/Ubuntu host, no image and no checkout involved.
