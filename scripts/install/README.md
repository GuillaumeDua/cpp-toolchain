# Toolchain installation scripts

Standalone scripts to install `CMake`, `GCC`, `LLVM/Clang`, and cross-compilation `binutils` (+ cross-libc), reusable on any Debian/Ubuntu-based system.  
All require root privileges, take no dependency on each other, and describe themselves with `--help`.

- `gcc.sh` and `llvm.sh` can install **multiple compiler versions side by side** in the same environment (one `apt install` per requested version, wired together with `update-alternatives`) - see their `--versions` option below.  
  Both default to `latest-stable`, i.e. a single version; pass a range (`>=11`), a list (`'11 12 13'`), or `all` to get more.
- `cmake.sh` does not have this multi-version story - see its own section below.
- `--silent` suppresses progress logs only: warnings and failures always reach `stderr`, and steps that touch the network are retried before giving up.

---

## `cmake.sh`

```bash
sudo ./cmake.sh [options]
```

Registers the [Kitware apt repository](https://apt.kitware.com/) (via its `kitware-archive.sh` bootstrap), then installs a single `cmake` version.
Unlike `gcc.sh`/`llvm.sh`, CMake has no side-by-side multi-version story (no `update-alternatives`) - the Kitware repo only ever exposes whichever versions are currently published.

| Option                   | Type    | Default  | Description                                                                                                                                                      |
| ------------------------ | ------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `-v`, `--versions`       | string  | `latest` | `latest` \| an upstream version (e.g. `'4.4.0'`) \| an exact apt version string as reported by `--list-available` (e.g. `'3.29.6-0kitware1ubuntu24.04.1'`) |
| `-l`, `--list-available` | boolean | `0`      | Only list the versions available via `apt-cache madison cmake`, without installing anything                                                                      |
| `-s`, `--silent`         | boolean | `1`      | Suppress log output                                                                                                                                              |
| `-a`, `--alias`          | boolean | `0`      | Append the resulting `cmake_version` variable to `/etc/bash.bashrc` and `/etc/zsh/zshrc`                                                                         |
| `-r`, `--rc`             | boolean | `0`      | Also register the Kitware release-candidate apt repository                                                                                                       |
| `-h`, `--help`           | -       | -        | Display usage                                                                                                                                                    |

Boolean values accept `y|yes|1|true` / `n|no|0|false` (case-insensitive).

**Example**: list available versions, then install a specific one:

```bash
sudo ./cmake.sh --list-available
sudo ./cmake.sh --versions="4.4.0"                                  # upstream version, resolved against apt
sudo ./cmake.sh --versions="3.29.6-0kitware1ubuntu24.04.1"          # exact apt version, used verbatim
```

An upstream version (`4.4.0`) is resolved to the `Kitware` apt version that carries it (`4.4.0-0kitware1ubuntu24.04.1`), newest first if several qualify.
That indirection is what makes `CMake` pinnable by automation: the apt version string is distro-specific and published by no upstream datasource, whereas the plain upstream version is exactly what release trackers do publish - so a caller can pin `4.4.0` and let a bot follow `Kitware/CMake` releases.

---

## `gcc.sh`

```bash
sudo ./gcc.sh [options]
```

Installs one or more GCC versions from the `ubuntu-toolchain-r/test` PPA (added automatically if missing), sets up `update-alternatives` for `gcc`/`g++`/`gcov`/`gcov-tool`, and (by default) installs the matching `-multilib` packages.

| Option                   | Type    | Default         | Description                                                                                              |
| ------------------------ | ------- | --------------- | -------------------------------------------------------------------------------------------------------- |
| `-v`, `--versions`       | string  | `latest-stable` | `all` \| `latest` \| `latest-stable` \| `>=<number>` \| space-separated version numbers (e.g. `'13 14'`) |
| `-l`, `--list-available` | boolean | `0`             | Only list the versions that `--versions` resolves to, without installing anything                        |
| `--list-installed`       | boolean | `0`             | Only list the major versions already installed, filtered by `--versions` when that is given explicitly.  |
| `-s`, `--silent`         | boolean | `1`             | Suppress log output                                                                                      |
| `-a`, `--alias`          | boolean | `0`             | Append the resulting `gcc_versions` variable to `/etc/bash.bashrc` and `/etc/zsh/zshrc`                  |
| `--multilib`             | boolean | `1`             | Install `gcc-<N>-multilib` / `g++-<N>-multilib` (secondary ABIs: `-m32`, `-mx32`)                        |
| `--mode`                 | string  | `full`          | How much of the toolchain to install: `runtime` \| `minimalistic` \| `full` - see below                  |
| `-m`, `--minimalistic`   | boolean | `0`             | Alias for `--mode=minimalistic`, kept for compatibility                                                  |
| `-h`, `--help`           | -       | -               | Display usage                                                                                            |

| `--mode`       | Installs                                                                |
| -------------- | ----------------------------------------------------------------------- |
| `runtime`      | `libstdc++6` `libgcc-s1` - the shared libraries, no compiler            |
| `minimalistic` | `gcc-<N>` `g++-<N>`; disables `--multilib` unless it was set explicitly |
| `full`         | the above plus `gcc-<N>-multilib` / `g++-<N>-multilib`                  |

`runtime` takes no `--versions`: `libstdc++6` and `libgcc-s1` carry no major in their name, one install serves every compiler, and there is nothing for a version selector to choose between.
It is what the [Dockerfile](../../Dockerfile)'s `runtime` stage installs, and it names the two packages the [validation gate](../../docs/IMAGES_VALIDATION.md) expects from this PPA - so that expectation is written down once rather than in both places.

Boolean values accept `y|yes|1|true` / `n|no|0|false` (case-insensitive).

**Multilib is best-effort by default**: the packages lag for brand-new GCC versions and do not exist on non-`amd64` hosts, so an unavailable one is skipped with a warning.  
An *explicit* `--multilib=yes` is honored strictly and fails hard instead - the default resolution is resilient, an explicit request is not silently ignored.

**Example**: install the two latest available versions:

```bash
sudo ./gcc.sh --versions="$(sudo ./gcc.sh --list-available --versions='all' | tail -2)"
sudo ./gcc.sh --mode=minimalistic                 # compilers only, no multilib
sudo ./gcc.sh --mode=minimalistic --multilib=yes  # explicit multilib still wins
sudo ./gcc.sh --mode=runtime                      # libstdc++6 + libgcc-s1, no compiler
```

---

## `llvm.sh`

```bash
sudo ./llvm.sh [options]
```

Wraps the upstream [`apt.llvm.org/llvm.sh`](https://apt.llvm.org/llvm.sh) installer:

- fetches it (and the LLVM apt signing key) into a temporary `impl.sh`
- resolves the requested version(s)
- installs the package set `--mode` selects
- then sets up `update-alternatives` for `clang`/`clang++` and, in `--mode=full`, the rest of the toolchain (`clang-format`, `clang-tidy`, `clangd`, `lldb`, `scan-build`, `llvm-cov`, `llvm-profdata`, ...)
- *The temporary `impl.sh` is removed before exit*

| Option                   | Type    | Default         | Description                                                                                              |
| ------------------------ | ------- | --------------- | -------------------------------------------------------------------------------------------------------- |
| `-v`, `--versions`       | string  | `latest-stable` | `all` \| `latest` \| `latest-stable` \| `>=<number>` \| space-separated version numbers (e.g. `'17 18'`) |
| `-l`, `--list-available` | boolean | `0`             | Only list the versions that `--versions` resolves to, without installing anything                        |
| `--list-installed`       | boolean | `0`             | Only list the major versions already installed, filtered by `--versions` when that is given explicitly   |
| `-s`, `--silent`         | boolean | `1`             | Suppress log output                                                                                      |
| `-a`, `--alias`          | boolean | `0`             | Append the resulting `llvm_versions` variable to `/etc/bash.bashrc` and `/etc/zsh/zshrc`                 |
| `--mode`                 | string  | `full`          | How much of the toolchain to install: `runtime` \| `minimalistic` \| `coverage` \| `full` - see below    |
| `-c`, `--cleanup`        | boolean | `0`             | Purge any pre-existing `llvm-*`/`lldb-*`/`clang-*`/`python3-lldb-*` packages before installing           |
| `-h`, `--help`           | -       | -               | Display usage                                                                                            |

The three modes are tiered, and each one selects both the **packages installed** and the **`update-alternatives` registered**:

| `--mode`       | Installs                                                                     | Registers unversioned                                               |
| -------------- | ---------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| `runtime`      | `libc++1` `libc++abi1` - the shared libraries, no compiler and no headers    | nothing                                                             |
| `minimalistic` | `clang` `lld` `lldb` `clangd` + the compiler runtimes                        | `clang`, `clang++`                                                  |
| `coverage`     | the above + `llvm-<N>`                                                       | + `llvm-cov`, `llvm-profdata`                                       |
| `full`         | the upstream `all` set - analysis tools, `libclang` development headers, ... | + `clang-tidy`, `clang-format`, `clangd`, `lldb`, `scan-build`, ... |

`runtime` is the only mode that does not run the upstream installer at all - its smallest package set still starts with `clang-<N>`.  
It registers the same apt.llvm.org repository upstream would have, then installs those two packages and stops.  
`--versions` still selects which suite, because that is what decides the libc++ release,  
but nothing is registered under an unversioned name: there is no binary to alternate between.

It needs **LLVM 20 or later**, and says so rather than guessing: apt.llvm.org carried the major in these package names until then, and spelled it inconsistently - `libc++1-18` and `libc++1-19`, but `libc++1-17t64` across the `time_t` transition.  
`libunwind` is deliberately absent, since `apt.llvm.org` builds `libc++abi` against `libgcc_s`, which every Debian-derived image already has.

The *compiler runtimes* are the libc++ stack (`libc++-<N>-dev`, `libc++abi-<N>-dev`, `libunwind-<N>-dev`), OpenMP (`libomp-<N>-dev`) and, from LLVM 15, the sanitizer and Polly runtimes (`libclang-rt-<N>-dev`, `libpolly-<N>-dev`).
Every mode that installs a compiler installs them: they are compiler capabilities - `-stdlib=libc++`, `-fopenmp`, `-fsanitize=...` - rather than tools, so a `minimalistic` install still compiles everything a `full` one does.

Boolean values accept `y|yes|1|true` / `n|no|0|false` (case-insensitive).

`update-alternatives` priority is the version number, so the **highest installed version** wins the unversioned `clang`/`clang++` - the same rule `gcc.sh` uses.

The modes are meant to be **layered**: a first `--mode=minimalistic` run installs and registers only the compilers, and a later `--mode=full` run over the same environment adds `clang-tidy`/`clang-format`/`clangd`/`lldb`/`scan-build` without touching them.
Useful when a compile-only environment and a full analysis one are built from a common base - which is exactly how the [Dockerfile](../../Dockerfile)'s `build` and `static-analysis` stages relate.

`runtime` layers the same way, from underneath: it puts `libc++1` in place, and a later `--mode=minimalistic` run over it adds the compiler and headers that match.  
That is how `build` sits on `runtime` - one library, installed once, at the bottom of the stack where the image that only has to *run* things can stop.

Example: install the two latest available versions:

```bash
sudo ./llvm.sh --versions="$(sudo ./llvm.sh --list-available --versions='all' | tail -2)"
```

---

## `binutils.sh`

```bash
sudo ./binutils.sh [options]
```

Installs a **complete cross toolchain** for each target.  
An empty target list (`--targets=''`) installs nothing and exits successfully, so a caller can make cross support conditional without branching around the call.

By default (`--with-gcc=1`) installs `g++-<triplet>`, which transitively pulls the whole set - cross **binutils** (`as`, `ld`, `objdump`, `readelf`, `strip`),  
cross **glibc**, cross **libgcc** and cross **libstdc++** - laid out under `/usr/lib/gcc-cross/<triplet>/`.  
That is enough to compile *and link* C and C++ for the target, and Clang's driver **auto-detects** the cross-GCC install, so `clang --target=<triplet>` works (with libstdc++) too.

With `--with-gcc=0`, or for targets that have no cross-`g++`, it falls back to bare `binutils-<triplet>` + `libc6-dev-<debarch>-cross`:

- enough to compile to objects and inspect/strip
- but **not** to link a full executable (no target `libgcc` / `libstdc++`).

This fallback is compiler-agnostic - the bare binutils serve any toolchain emitting that arch, which is why cross tooling lives here rather than in `gcc.sh` (`gcc.sh` owns `--multilib`, a secondary ABI of the *host* arch - a different thing).

| Option                   | Type    | Default    | Description                                                                                                                                  |
| ------------------------ | ------- | ---------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `-t`, `--targets`        | string  | `'common'` | Space-separated GNU target triplets, or `common`, or `all`                                                                                   |
| `--list-targets`         | boolean | `0`        | Only print the triplets `--targets` resolves to, without consulting apt. A pure query, and how anything downstream resolves `common`         |
| `--with-gcc`             | boolean | `1`        | Install `g++-<triplet>` (full toolchain, links C/C++); `0` = bare binutils + libc                                                            |
| `-l`, `--list-available` | boolean | `0`        | Only list the cross target triplets available on this host, restricted to `--targets`. Use `--targets=all` for every triplet the host offers |
| `--list-installed`       | boolean | `0`        | Only list the cross target triplets already installed, restricted to `--targets` when that is given explicitly.                              |
| `-s`, `--silent`         | boolean | `1`        | Suppress log output                                                                                                                          |
| `-h`, `--help`           | -       | -          | Display usage                                                                                                                                |

Boolean values accept `y|yes|1|true` / `n|no|0|false` (case-insensitive).

Each target is installed **best-effort** - availability is host/arch dependent, so an unavailable package is skipped with a warning rather than failing the run.  
**25 of 32** targets have a cross-`g++`; the 7 without one (`ia64`, `hppa64`, `loongarch64`, and the four mips-`n32` variants) automatically use the binutils + libc fallback.

**CPU, FPU and ABI variants are encoded in the triplet** - there is no separate switch:

| Axis       | Example triplets                                                           |
| ---------- | -------------------------------------------------------------------------- |
| FPU        | `arm-linux-gnueabi` (soft-float) vs `arm-linux-gnueabihf` (hard-float VFP) |
| ABI        | `mips64-linux-gnuabi64` (n64) vs `mips64-linux-gnuabin32` (n32)            |
| ABI        | `x86-64-linux-gnu` (LP64) vs `x86-64-linux-gnux32` (x32)                   |
| CPU / ISA  | `mipsisa32r6-linux-gnu`, `mipsisa64r6el-linux-gnuabi64` (MIPS release 6)   |
| Endianness | `powerpc64` vs `powerpc64le`, `mips` vs `mipsel`                           |

In the fallback path, cross-libc packages key off the **Debian architecture alias**, not the GNU triplet (`aarch64-linux-gnu` → `arm64`, `mipsisa64r6el-linux-gnuabin32` → `mipsn32r6el`), so the script carries an internal `triplet_to_deb_arch` lookup table (29 triplets; `alpha`, `hppa64`, `ia64` have no cross-libc and get binutils only).

`common` is the set these images ship - `aarch64-linux-gnu`, `arm-linux-gnueabihf`, `riscv64-linux-gnu`, `x86-64-linux-gnu` - and `binutils.sh` is where that list lives.
Nothing else in the repository repeats it: the workflows pass `common` through as `BINUTILS_TARGETS`, and the validation gate expands it with `--list-targets`.

**Example**: discover the available targets, then install a couple:

```bash
sudo ./binutils.sh --list-available --targets=all
sudo ./binutils.sh --targets='powerpc64le-linux-gnu s390x-linux-gnu'
sudo ./binutils.sh --targets='aarch64-linux-gnu' --with-gcc=no   # bare binutils + libc only

./binutils.sh --list-installed                                   # what this host already carries
./binutils.sh --list-installed --targets='aarch64-linux-gnu riscv64-linux-gnu'
```

`--list-available` without `--targets` answers "which of the defaults exist here", the same way `gcc.sh --list-available` answers for its default `--versions`.
`--targets=all` is what lists every triplet the host offers.

With a cross-`g++` (the default), C and C++ both compile *and link* for the target, with GNU cross tools or with Clang:

```bash
aarch64-linux-gnu-g++ main.cpp -o app        # GNU cross g++
clang++ --target=aarch64-linux-gnu main.cpp  # Clang, libstdc++ (auto-detected)
```

> [!IMPORTANT]
> **Current limitation**: The **GCC-free** cross path - Clang with **libc++** *for the target* (`-stdlib=libc++`) - is **not** bundled:  
> `libc++` has no portable apt cross package and requires an LLVM `runtimes` source build (tracked as a future `libcxx.sh`).  
> The *host* libc++ **is** installed by `llvm.sh`, so native `clang++ -stdlib=libc++` works without GCC - only the cross case is missing.
