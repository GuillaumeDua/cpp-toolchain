# Image validation checks

The gate that every image passes before it is published. What each check proves, which stage runs
it and how to reproduce a failure locally: [docs/IMAGES_VALIDATION.md](../../docs/IMAGES_VALIDATION.md).

Unlike the [repository tooling](../details/README.md) next door, these run **inside** a built
image - the validate stages copy `scripts/` in and execute them there.

## Standalone

| Script | Purpose |
| ------ | ------- |
| `check-compiler-supported-cxx-standards.sh` | Which C++ standards a compiler accepts, ordered by `__cplusplus` |

This one depends on nothing in this repository - point it at any compiler on any machine. Fetch
it on its own when you want the answer without an image or a checkout:

```bash
wget https://raw.githubusercontent.com/GuillaumeDua/cpp-toolchain/main/scripts/checks/check-compiler-supported-cxx-standards.sh
```

From a checkout it is the same script:

```bash
scripts/checks/check-compiler-supported-cxx-standards.sh --stable g++-16
c++03 -> __cplusplus=199711
...
c++26 -> __cplusplus=202400
```

`--stable` drops draft spellings such as `c++2c`, `--greatest` keeps only the highest standard,
and `--format` narrows each line to one field - `std` for `c++26`, `cplusplus` for `202400`.
`--format=std` is spelled the way the compiler spells it, so it feeds straight back in:

```bash
g++-16 -std="$(scripts/checks/check-compiler-supported-cxx-standards.sh --greatest --stable --format=std g++-16)" main.cpp
```

`--help` is the full reference.

## [details/](details/)

| Script | Purpose |
| ------ | ------- |
| `check-package-origins.sh <build\|runtime>` | Every toolchain package comes from the repository that owns it, not from the Ubuntu archive |
| `check-cxx-runtime.sh <compile\|inspect\|run> <directory>` | Compiles the payload for every standard, proves it links against a C++ runtime dynamically, then runs it |

Implementation details of this gate, in the C++ sense of a nested `detail` namespace: they know
this repo's expected package origins, and they ask [`scripts/install/`](../install/) which
compilers are installed rather than guessing. That reach is why the validate stages copy `scripts/`
whole - a layout that separates the two fails loudly rather than silently finding no compilers.

Both report **every** failure before exiting, so one run tells you everything that is wrong.
Both also run against a plain checkout, which is the quickest way to iterate on them; they
discover whatever the host has, so expect a wider matrix than an image produces.
