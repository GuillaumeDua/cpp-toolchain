# Image verification suite

Answers two questions about a built image, before it is published:

| Question | Answered by |
| -------- | ----------- |
| Does it contain the versions the Dockerfile pins? | [`verify-image.py`](verify-image.py) + [`probe.sh`](probe.sh) |
| Does the toolchain actually work? | [`smoke/`](smoke/) |

## The one rule

**No version number appears outside the [Dockerfile](../../../Dockerfile).**

That is enforced structurally, not by convention. The suite is split in two halves:

- **`probe.sh`** runs *inside* the image, reports facts as `key<TAB>value`, and asserts nothing.
  It has no field to write a version into, so it cannot duplicate one.
- **`verify-image.py`** runs *on the host*, reads the pins through
  [`render-manifest.py`](../render-manifest.py)'s `parse()` - which runs the `renovate.json` manager
  regexes - and decides whether the reported facts are the right ones.

So what Renovate tracks, what [`check-dependencies-pins.py`](../check-dependencies-pins.py)
enforces, what the release note lists, and what this asserts all come from one definition. Bumping a
version is a one-line change to the Dockerfile; nothing here needs touching.

`verify-image.py --self-test` includes a check that `probe.sh` contains no version-shaped text.

## Files

| File | Runs | Purpose |
| ---- | ---- | ------- |
| `probe.sh` | in the image | Reports facts. Restricted to what `runtime` ships: bash, coreutils, `ldconfig`, `readlink`, `dpkg-query` |
| `verify-image.py` | on the host | Every assertion, plus `--self-test` and `--print-expectations` |
| `smoke/cxx23.cpp` | compiled in the image | `std::print`, `std::expected`, deducing `this`, `constexpr std::vector` |
| `smoke/run.sh` | in the image | Compiles and runs the payload with every default compiler |
| `smoke/cross.sh` | in the image | Cross-compiles the payload `-static` for each triplet |
| `smoke/runtime-abi.cpp` | compiled in `build`, run in `runtime` | A `std::string` past SSO plus a thrown exception - the libstdc++ and unwinder path |
| `run-cross.sh` | on the host | Drives `cross.sh`, then executes the artifacts under qemu |
| `run-runtime-abi.sh` | on the host | Spans two images, so it cannot live in a per-stage loop |

The tests reach an image by **bind mount**, never by `COPY`: `scripts/details` is excluded from the
build context in [`.dockerignore`](../../../.dockerignore), so nothing here can end up inside a
published image.

## Usage

```bash
# no Docker required
python3 scripts/details/tests/verify-image.py --self-test
python3 scripts/details/tests/verify-image.py --print-expectations --all

# against a built image
docker build --target build -t cpp-toolchain:build .
python3 scripts/details/tests/verify-image.py --stage build --image cpp-toolchain:build
docker run --rm -v "${PWD}/scripts/details/tests:/opt/cpp-toolchain-tests:ro" \
    cpp-toolchain:build bash /opt/cpp-toolchain-tests/smoke/run.sh

# the two that need more than one image, or the host
bash scripts/details/tests/run-cross.sh cpp-toolchain:build-cross
bash scripts/details/tests/run-runtime-abi.sh cpp-toolchain:build cpp-toolchain:runtime
```

## Things worth knowing before changing this

- **`GCC_VERSIONS` is a selector, not a version.** It accepts `15`, `9 11 13`, `>=13`, `all`,
  `latest` and `latest-stable`; only the first two resolve without knowing what the PPA offered at
  build time. The rest are asserted as a constraint. See `parse_selector`.
- **More than one compiler major is installed even at `GCC_VERSIONS=15`**, because Ubuntu's own
  `g++-13` arrives transitively. The suite never asserts that a major is *absent*. What it does
  assert is that the unversioned `g++` resolves to the highest requested one - a broken
  `update-alternatives` registration is the failure nothing else here would notice.
- **The cross toolchain's version is pinned by nothing.** `binutils.sh` installs unversioned
  `g++-<triplet>` from the snapshot-pinned archive, so it is the distro's GCC, not `GCC_VERSIONS`.
  Only presence and mutual consistency are asserted.
- **Cross presence is gated on the package, not the binary.** Debian multiarch puts
  `/usr/bin/x86_64-linux-gnu-g++` in every image as an alias for the native compiler, so a
  filesystem check reports `x86-64-linux-gnu` as present in a lean image with no cross toolchain at
  all.
- **`g++-x86-64-linux-gnu` installs `/usr/bin/x86_64-linux-gnu-g++`.** Debian package names cannot
  contain underscores. Anything mapping between triplet and binary must normalise both spellings -
  one of the four published triplets is affected, which is how a hand-written mapping survives
  review while being wrong.
- **A failing assertion is a finding, not a reason to loosen it.** If an image does not contain what
  the Dockerfile says it does, that is the bug the suite exists to surface.
