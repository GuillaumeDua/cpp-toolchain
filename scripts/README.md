# Standalone scripts

The public scripts are published self-contained: fetch one from a release and run it on any Debian/Ubuntu-based host, with no image and no checkout involved.
In this repository they source their shared helpers instead of carrying them, so fetch the published copy rather than the file here - see [Using a public script on its own](#using-a-public-script-on-its-own).
[Using the images](../docs/IMAGES.md) is the Docker route instead.

| Directory | Scope | What lives there |
| --------- | ----- | ---------------- |
| [install/](install/) | **Public** - standalone | Toolchain installers - `cmake.sh`, `gcc.sh`, `llvm.sh`, `binutils.sh`, `doxygen.sh`. Reusable on any Debian/Ubuntu-based system, with no dependency on this repository. See [install/README.md](install/README.md) for the full option reference. |
| [checks/](checks/) | **Public** - standalone | `cxx-standards.sh` - which C++ standards a compiler accepts. `cxx-stdlibs.sh` - which C++ standard libraries are installed, with the `SONAME` and ABI version a binary will need to find. `c-stdlibs.sh` - the same, for the C standard library. Point either at any machine, checkout or not. See [checks/README.md](checks/README.md). |
| [checks/details/](checks/details/) | Internal | The image validation gate, which runs *inside* a built image: it knows this repo's expected package origins and asks its installers what is present. See [docs/IMAGES_VALIDATION.md](../docs/IMAGES_VALIDATION.md). |
| [details/](details/) | Internal | This repository's own tooling - the version-pin guard, the release-note renderer, the install-script parity check, the shared helper library those copies come from, the promotion-record schema and the image smoke test. Not reusable: they parse this repo's `Dockerfile`, `renovate.json` and `releases/` records. See [details/README.md](details/README.md). |

The [Dockerfile](../Dockerfile) copies in and runs the `install/` scripts, one per stage that needs one, and copies `scripts/` whole into the throwaway validate stages so `checks/` can run there.  
Nothing under the top-level `details/` ever enters an image: `.dockerignore` keeps it out of the build context entirely, and the smoke test reaches a built image by bind-mount instead.

`checks/details/` is a different `details/` - implementation details of `checks/`, in the C++ sense of a nested `detail` namespace.
Being repo-specific is what the two share; unlike the top-level one, these *must* ship into the image they validate.

## Using a public script on its own

> [!CAUTION]
> For all scripts in this repo:
>
> - Optional value needs `<name>=<value>` semantic
> - There are no positional arguments.

Everything marked **Public** is published as a single file that needs nothing around it, so you can drop it into a project, a CI job or a plain shell - no image to pull, no repository to clone, no commitment to the rest of this toolchain:

```bash
base=https://github.com/GuillaumeDua/cpp-toolchain/releases/latest/download

# Install a toolchain on any Debian/Ubuntu-based host
wget "${base}/gcc.sh"
sudo bash gcc.sh --versions='>=13'

# Ask a compiler which C++ standards it accepts - useful to drive a CI matrix
wget "${base}/cxx-standards.sh"
bash cxx-standards.sh --greatest --stable --format=std g++
# -> c++26

# Ask which ABI the installed libstdc++ exposes - the marker a 'GLIBCXX_... not found' names
wget "${base}/cxx-stdlibs.sh"
bash cxx-stdlibs.sh --stdlib=libstdc++ --format=abi
# -> GLIBCXX_3.4.35

# The same question about the C standard library
wget "${base}/c-stdlibs.sh"
bash c-stdlibs.sh --format=abi
# -> GLIBC_2.39
```

Every one of them describes itself with `--help`, so the fetched file is its own documentation.

`latest` is the newest release, and skips the release candidates. Swap it for `download/<tag>` when you want the URL pinned, which is what you usually want in CI:

```bash
base=https://github.com/GuillaumeDua/cpp-toolchain/releases/download/v1.3
```

> [!NOTE]
> The file in this repository is not the file you download.
> Here, each script sources its shared helpers from [details/shared.sh](details/shared.sh), so a helper is written once.
> The published copy carries them inlined, which is what makes it runnable on its own - see [details/compose-standalone.py](details/compose-standalone.py).
> Fetching `scripts/install/gcc.sh` out of the repository gets you a script that cannot find its helpers.

The `Internal` rows are not published at all.
They reach the rest of the tree by relative path and only work inside a checkout or an image.
