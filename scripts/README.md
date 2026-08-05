# Scripts

Two kinds, kept apart because only one of them is meant to leave this repository.

| Directory | What lives there |
| --------- | ---------------- |
| [install/](install/) | Toolchain installers - `cmake.sh`, `gcc.sh`, `llvm.sh`, `binutils.sh`, `doxygen.sh`. Standalone and reusable on any Debian/Ubuntu-based system, with no dependency on this repository. See [install/README.md](install/README.md) for the full option reference. |
| [details/](details/) | This repository's own tooling - the version-pin guard, the release-note renderer and the promotion-record schema. Not reusable: they parse this repo's `Dockerfile`, `renovate.json` and `releases/` records. See [details/README.md](details/README.md). |

The [Dockerfile](../Dockerfile) copies in and runs the `install/` scripts, one per stage that needs
one; nothing under `details/` ever enters an image.
