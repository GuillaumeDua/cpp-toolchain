# Cross-architecture compilation & multilib

Two different things, both available from the **`build`** stage onwards:

- [Cross-architecture compilation](#cross-architecture-compilation) - targeting *another* architecture (`arm64`, `riscv64`, ...), **opt-in**
- [Multilib](#multilib---secondary-abis) - a *secondary ABI of the host* architecture (`-m32`, `-mx32`), installed by default

## Cross-architecture compilation

Cross-arch is **opt-in**: the default (lean) images ship no cross toolchain. You get it either by pulling a **`-cross` image** or by building any stage with `--build-arg BINUTILS_TARGETS='<triplets>'`.

```bash
# pull the published cross variant of a stage
docker pull ghcr.io/guillaumedua/cpp-toolchain:build-cross-latest

# or build your own, with your own targets
docker build --target build \
    -t cpp-toolchain:build-cross \
    --build-arg BINUTILS_TARGETS='aarch64-linux-gnu powerpc64le-linux-gnu' .
```

For each requested target, [`binutils.sh`](../scripts/install/binutils.sh) installs a **complete cross toolchain** via `g++-<triplet>` - which pulls cross **binutils** (`as` / `ld` / `objdump` / ...), cross **glibc**, cross **libgcc** and cross **libstdc++**.  
That is enough to compile *and link* C and C++ for the target, and Clang auto-detects the cross-GCC install, so `clang --target=<triplet>` works with no extra flags.

### Published targets

The `-cross` images carry the live non-x86 ecosystems - ARM 64-bit (servers/embedded), ARM 32-bit (embedded) and RISC-V:

| Target triplet        | Package installed         | Pulls (cross)                             |
| --------------------- | ------------------------- | ----------------------------------------- |
| `aarch64-linux-gnu`   | `g++-aarch64-linux-gnu`   | binutils · glibc · libgcc · **libstdc++** |
| `arm-linux-gnueabihf` | `g++-arm-linux-gnueabihf` | binutils · glibc · libgcc · **libstdc++** |
| `riscv64-linux-gnu`   | `g++-riscv64-linux-gnu`   | binutils · glibc · libgcc · **libstdc++** |

A custom build can name any triplet from `binutils.sh --list-available --targets=all`, or `common` for the published set - **CPU, FPU, ABI and endianness are selected by the triplet itself**, there is no separate switch.  
See [scripts/install/README.md](../scripts/install/README.md#binutilssh) for the axes, the full option reference, and the 7 triplets (out of 32) that have no cross-`g++` and fall back to bare binutils.

### What works, and what does not

Assuming the target has a cross-`g++` (the published targets do):

| Capability                                           | Status                                   |
| ---------------------------------------------------- | ---------------------------------------- |
| Cross-compile + **link** **C**                       | ✅                                       |
| Cross-compile + **link** **C++** (libstdc++)         | ✅                                       |
| `clang --target=<triplet>` (C and C++, libstdc++)    | ✅ auto-detects the cross-GCC install    |
| Inspect / strip target objects (`objdump` / `strip`) | ✅                                       |
| Cross-compile **C++** with **libc++**                | ❌ target libc++ not bundled - see below |

```bash
aarch64-linux-gnu-g++ main.cpp -o app                        # ✅ GNU cross g++
clang++ --target=aarch64-linux-gnu main.cpp                  # ✅ clang, libstdc++ (auto-detected)
clang++ --target=aarch64-linux-gnu -stdlib=libc++ main.cpp   # ❌ no target libc++
```

**libc++ for the target** (the GCC-free path) is **not bundled** - it has no portable apt cross package and requires an LLVM `runtimes` source build, tracked as a future `scripts/libcxx.sh`. This affects the *cross* case only: the **host** libc++ is installed, so native `clang++ -stdlib=libc++` works.

## Multilib - secondary ABIs

Distinct from cross-compilation: multilib is the *same* GCC emitting a **secondary ABI of the host architecture**, via `gcc-<N>-multilib` / `g++-<N>-multilib` (which pull `libc6-dev-i386`, `libc6-dev-x32`, `lib32stdc++-<N>-dev`, ...).

```bash
g++ -m64  main.cpp   # native LP64 (default)
g++ -m32  main.cpp   # 32-bit x86 (i386)
g++ -mx32 main.cpp   # x32 - 32-bit pointers, 64-bit registers
```

Installed by default, **best-effort**: multilib lags for brand-new GCC versions and does not exist on non-amd64 hosts, so an unavailable package is skipped with a log rather than failing the build. `gcc.sh` exposes `--multilib` (default on) and `-m` / `--minimalistic` (compilers only); an *explicit* `--multilib=yes` is honored strictly and fails hard if unavailable.

## See also

- [README.md](../README.md) - images, features, tags, build arguments.
- [scripts/install/README.md](../scripts/install/README.md#binutilssh) - `binutils.sh` reference: available triplets, triplet axes, fallback behaviour.
- [docs/COVERAGE.md](COVERAGE.md) - GNU and LLVM code coverage.
