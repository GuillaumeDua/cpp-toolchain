# Toolchain installation scripts

Standalone scripts to install `CMake`, `GCC`, `LLVM/Clang`, and cross-compilation `binutils` (+ cross-libc), reusable on any Debian/Ubuntu-based system.  
All require root privileges. Used by the [devcontainer](../Dockerfile) and the `WSL2` integrations.

`gcc.sh` and `llvm.sh` can install **multiple compiler versions side by side** in the same environment (one `apt install` per requested version, wired together with `update-alternatives`) — see their `--versions` option below. The published Docker image only requests `latest-stable` for both by default to keep the image lean; pass a range (`>=11`), a list (`'11 12 13'`), or `all` via `--build-arg GCC_VERSIONS=...` / `LLVM_VERSIONS=...` to get more of them baked into your own build. `cmake.sh` does not have this multi-version story — see its own section below.

---

## `cmake.sh`

```bash
sudo ./cmake.sh [options]
```

Registers the [Kitware apt repository](https://apt.kitware.com/) (via its `kitware-archive.sh` bootstrap, handling the Ubuntu-24.04-noble → jammy quick-fix), then installs a single `cmake` version. Unlike `gcc.sh`/`llvm.sh`, CMake has no side-by-side multi-version story (no `update-alternatives`) — the Kitware repo only ever exposes whichever versions are currently published.

| Option             | Type    | Default  | Description                                                                                                |
| ------------------ | ------- | -------- | ---------------------------------------------------------------------------------------------------------- |
| `-v`, `--versions` | string  | `latest` | `latest` \| an exact version string as reported by `--list` (e.g. `'3.29.3-0kitware1ubuntu24.04.1~jammy'`) |
| `-l`, `--list`     | boolean | `0`      | Only list the versions available via `apt-cache madison cmake`, without installing anything                |
| `-s`, `--silent`   | boolean | `1`      | Suppress log output                                                                                        |
| `-a`, `--alias`    | boolean | `0`      | Append the resulting `cmake_version` variable to `/etc/bash.bashrc` and `/etc/zsh/zshrc`                   |
| `-r`, `--rc`       | boolean | `0`      | Also register the Kitware release-candidate apt repository                                                 |
| `-h`, `--help`     | —       | —        | Display usage                                                                                              |

Boolean values accept `y|yes|1|true` / `n|no|0|false` (case-insensitive).

**Example**: list available versions, then install a specific one:

```bash
sudo ./cmake.sh --list
sudo ./cmake.sh --versions="3.29.3-0kitware1ubuntu24.04.1~jammy"
```

---

## `gcc.sh`

```bash
sudo ./gcc.sh [options]
```

Installs one or more GCC versions from the `ubuntu-toolchain-r/test` PPA (added automatically if missing), sets up `update-alternatives` for `gcc`/`g++`/`gcov`/`gcov-tool`, and (by default) installs the matching `-multilib` packages.

| Option                 | Type    | Default         | Description                                                                                              |
| ---------------------- | ------- | --------------- | -------------------------------------------------------------------------------------------------------- |
| `-v`, `--versions`     | string  | `latest-stable` | `all` \| `latest` \| `latest-stable` \| `>=<number>` \| space-separated version numbers (e.g. `'13 14'`) |
| `-l`, `--list`         | boolean | `0`             | Only list the versions that `--versions` resolves to, without installing anything                        |
| `-s`, `--silent`       | boolean | `1`             | Suppress log output                                                                                      |
| `-a`, `--alias`        | boolean | `0`             | Append the resulting `gcc_versions` variable to `/etc/bash.bashrc` and `/etc/zsh/zshrc`                  |
| `--multilib`           | boolean | `1`             | Install `gcc-<N>-multilib` / `g++-<N>-multilib` (secondary ABIs: `-m32`, `-mx32`)                        |
| `-m`, `--minimalistic` | boolean | `0`             | Compilers only — disables `--multilib` *unless* it was set explicitly                                    |
| `-h`, `--help`         | —       | —               | Display usage                                                                                            |

Boolean values accept `y|yes|1|true` / `n|no|0|false` (case-insensitive).

**Multilib is best-effort by default**: the packages lag for brand-new GCC versions and do not exist on non-amd64 hosts, so an unavailable one is skipped with a log. An *explicit* `--multilib=yes` is honored strictly and fails hard instead — the default resolution is resilient, an explicit request is not silently ignored.

**Example**: install the two latest available versions:

```bash
sudo ./gcc.sh --versions="$(sudo ./gcc.sh --list --versions='all' | tail -2)"
sudo ./gcc.sh --minimalistic                 # compilers only, no multilib
sudo ./gcc.sh --minimalistic --multilib=yes  # explicit multilib still wins
```

---

## `llvm.sh`

```bash
sudo ./llvm.sh [options]
```

Wraps the upstream [`apt.llvm.org/llvm.sh`](https://apt.llvm.org/llvm.sh) installer:

- fetches it (and the LLVM apt signing key) into a temporary `impl.sh`
- resolves the requested version(s)
- installs them
- then sets up `update-alternatives` for `clang`/`clang++` and (unless `--minimalistic`) the full toolchain (`clang-format`, `clang-tidy`, `clangd`, `lldb`, `scan-build`, `llvm-cov`, `llvm-profdata`, ...)
- *The temporary `impl.sh` is removed before exit*

| Option                 | Type    | Default         | Description                                                                                              |
| ---------------------- | ------- | --------------- | -------------------------------------------------------------------------------------------------------- |
| `-v`, `--versions`     | string  | `latest-stable` | `all` \| `latest` \| `latest-stable` \| `>=<number>` \| space-separated version numbers (e.g. `'17 18'`) |
| `-l`, `--list`         | boolean | `0`             | Only list the versions that `--versions` resolves to, without installing anything                        |
| `-s`, `--silent`       | boolean | `1`             | Suppress log output                                                                                      |
| `-a`, `--alias`        | boolean | `0`             | Append the resulting `llvm_versions` variable to `/etc/bash.bashrc` and `/etc/zsh/zshrc`                 |
| `-m`, `--minimalistic` | boolean | `0`             | Only register `clang`/`clang++` alternatives, skip the extra tools                                       |
| `--coverage`           | boolean | `0`             | `clang`/`clang++` **+ coverage tools** (`llvm-cov`, `llvm-profdata`), without the analysis tools         |
| `-c`, `--cleanup`      | boolean | `0`             | Purge any pre-existing `llvm-*`/`lldb-*`/`clang-*`/`python3-lldb-*` packages before installing           |
| `-h`, `--help`         | —       | —               | Display usage                                                                                            |

The three alternative "mods" are tiered — `--minimalistic` (compilers) ⊂ `--coverage` (compilers + `llvm-cov`/`llvm-profdata`) ⊂ default (everything). `--coverage` is a superset of `--minimalistic`, so when both are passed **`--coverage` wins**.

> [!NOTE]
> These flags only control which `update-alternatives` symlinks are registered — the underlying *packages* are always installed (the upstream installer is invoked with `all`). So `llvm-cov-<N>` exists even after `--minimalistic`; only the unversioned `llvm-cov` command does not.

Boolean values accept `y|yes|1|true` / `n|no|0|false` (case-insensitive).

The latest stable version (per upstream's `CURRENT_LLVM_STABLE`) always gets `update-alternatives` priority `100`; other versions are prioritized by their version number.

The multi-stage [Dockerfile](../Dockerfile) relies on `--minimalistic`: the `build` stage runs `llvm.sh --minimalistic` (registers only `clang`/`clang++`, keeping analysis tools out of the compile-only image), then the `static-analysis` stage re-runs `llvm.sh` non-minimalistically to wire up `clang-tidy`/`clang-format`/`clangd`/`lldb`/`scan-build` (inherited by `dev`).

Example: install the two latest available versions:

```bash
sudo ./llvm.sh --versions="$(sudo ./llvm.sh --list --versions='all' | tail -2)"
```

---

## `binutils.sh`

```bash
sudo ./binutils.sh [options]
```

Installs a **complete cross toolchain** for each target. By default (`--with-gcc=1`) it installs `g++-<triplet>`, which transitively pulls the whole set — cross **binutils** (`as`, `ld`, `objdump`, `readelf`, `strip`), cross **glibc**, cross **libgcc** and cross **libstdc++** — laid out under `/usr/lib/gcc-cross/<triplet>/`. That is enough to compile *and link* C and C++ for the target, and Clang's driver **auto-detects** the cross-GCC install, so `clang --target=<triplet>` works (with libstdc++) too.

With `--with-gcc=0`, or for targets that have no cross-`g++`, it falls back to bare `binutils-<triplet>` + `libc6-dev-<debarch>-cross`: enough to compile to objects and inspect/strip, but **not** to link a full executable (no target `libgcc` / `libstdc++`). This fallback is compiler-agnostic — the bare binutils serve any toolchain emitting that arch, which is why cross tooling lives here rather than in `gcc.sh` (`gcc.sh` owns `--multilib`, a secondary ABI of the *host* arch — a different thing).

| Option            | Type    | Default                                   | Description                                                                        |
| ----------------- | ------- | ----------------------------------------- | ---------------------------------------------------------------------------------- |
| `-t`, `--targets` | string  | `'aarch64-linux-gnu powerpc64-linux-gnu'` | Space-separated GNU target triplets to install a cross toolchain for               |
| `--with-gcc`      | boolean | `1`                                       | Install `g++-<triplet>` (full toolchain, links C/C++); `0` = bare binutils + libc  |
| `-l`, `--list`    | boolean | `0`                                       | Only list the cross target triplets available on this host                         |
| `-s`, `--silent`  | boolean | `1`                                       | Suppress log output                                                                |
| `-h`, `--help`    | —       | —                                         | Display usage                                                                      |

Boolean values accept `y|yes|1|true` / `n|no|0|false` (case-insensitive).

Each target is installed **best-effort** — availability is host/arch dependent, so an unavailable package is logged and skipped rather than failing the run. **25 of 32** targets have a cross-`g++`; the 7 without one (`ia64`, `hppa64`, `loongarch64`, and the four mips-`n32` variants) automatically use the binutils + libc fallback.

**CPU, FPU and ABI variants are encoded in the triplet** — there is no separate switch:

| Axis       | Example triplets                                                           |
| ---------- | -------------------------------------------------------------------------- |
| FPU        | `arm-linux-gnueabi` (soft-float) vs `arm-linux-gnueabihf` (hard-float VFP) |
| ABI        | `mips64-linux-gnuabi64` (n64) vs `mips64-linux-gnuabin32` (n32)            |
| ABI        | `x86-64-linux-gnu` (LP64) vs `x86-64-linux-gnux32` (x32)                   |
| CPU / ISA  | `mipsisa32r6-linux-gnu`, `mipsisa64r6el-linux-gnuabi64` (MIPS release 6)   |
| Endianness | `powerpc64` vs `powerpc64le`, `mips` vs `mipsel`                           |

In the fallback path, cross-libc packages key off the **Debian architecture alias**, not the GNU triplet (`aarch64-linux-gnu` → `arm64`, `mipsisa64r6el-linux-gnuabin32` → `mipsn32r6el`), so the script carries an internal `triplet_to_deb_arch` lookup table (29 triplets; `alpha`, `hppa64`, `ia64` have no cross-libc and get binutils only).

**Example**: discover the available targets, then install a couple:

```bash
sudo ./binutils.sh --list
sudo ./binutils.sh --targets='riscv64-linux-gnu arm-linux-gnueabihf'
sudo ./binutils.sh --targets='aarch64-linux-gnu' --with-gcc=no   # bare binutils + libc only
```

With a cross-`g++` (the default), C and C++ both compile *and link* for the target, with GNU cross tools or with Clang:

```bash
aarch64-linux-gnu-g++ main.cpp -o app        # GNU cross g++
clang++ --target=aarch64-linux-gnu main.cpp  # Clang, libstdc++ (auto-detected)
```

> [!IMPORTANT]
> The **GCC-free** cross path — Clang with **libc++** *for the target* (`-stdlib=libc++`) — is **not** bundled: libc++ has no portable apt cross package and requires an LLVM `runtimes` source build (tracked as a future `libcxx.sh`). The *host* libc++ **is** installed by `llvm.sh`, so native `clang++ -stdlib=libc++` works without GCC — only the cross case is missing.
