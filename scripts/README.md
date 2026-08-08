# Scripts

Sorted by scope. **Public** means standalone and reusable as-is on any Debian/Ubuntu-based
system, with no dependency on this repository - copy the file out and it works. `Internal` means
it probes or parses this repo and only makes sense here.

| Directory | Scope | What lives there |
| --------- | ----- | ---------------- |
| [install/](install/) | **Public** - standalone | Toolchain installers - `cmake.sh`, `gcc.sh`, `llvm.sh`, `binutils.sh`, `doxygen.sh`. Reusable on any Debian/Ubuntu-based system, with no dependency on this repository. See [install/README.md](install/README.md) for the full option reference. |
| [checks/](checks/) | **Public** - standalone | `check-compiler-supported-cxx-standards.sh` - which C++ standards a compiler accepts. Point it at any compiler on any machine, checkout or not. See [checks/README.md](checks/README.md). |
| [checks/details/](checks/details/) | Internal | The image validation gate, which runs *inside* a built image: it knows this repo's expected package origins and asks its installers what is present. See [docs/IMAGES_VALIDATION.md](../docs/IMAGES_VALIDATION.md). |
| [details/](details/) | Internal | This repository's own tooling - the version-pin guard, the release-note renderer, the promotion-record schema and the image smoke test. Not reusable: they parse this repo's `Dockerfile`, `renovate.json` and `releases/` records. See [details/README.md](details/README.md). |

The [Dockerfile](../Dockerfile) copies in and runs the `install/` scripts, one per stage that needs
one, and copies `scripts/` whole into the throwaway validate stages so `checks/` can run there.
Nothing under the top-level `details/` ever enters an image: `.dockerignore` keeps it out of the
build context entirely, and the smoke test reaches a built image by bind-mount instead.

`checks/details/` is a different `details/` - implementation details of `checks/`, in the C++
sense of a nested `detail` namespace. Being repo-specific is what the two share; unlike the
top-level one, these *must* ship into the image they validate.

## Using a public script on its own

Everything marked **Public** is a single file that needs nothing around it, so you can pull it
straight from `raw.githubusercontent.com` and drop it into a project, a CI job or a plain shell -
no image to pull, no repository to clone, no commitment to the rest of this toolchain:

```bash
base=https://raw.githubusercontent.com/GuillaumeDua/cpp-toolchain/main/scripts

# Install a toolchain on any Debian/Ubuntu-based host
wget "${base}/install/gcc.sh"
sudo bash gcc.sh --versions='>=13'

# Ask a compiler which C++ standards it accepts - useful to drive a CI matrix
wget "${base}/checks/check-compiler-supported-cxx-standards.sh"
bash check-compiler-supported-cxx-standards.sh --greatest --stable --format=std g++
# -> c++26
```

Every one of them describes itself with `--help`, so the fetched file is its own documentation.

Swap `main` for a release tag when you want the URL pinned, which is what you usually want in CI -
`main` moves.

The `Internal` rows are not fetchable this way. They reach the rest of the tree by relative path
and only work inside a checkout or an image.
