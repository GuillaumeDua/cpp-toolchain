# Image verification suite

Answers two questions about a built image, before it is published:

| Question | Answered by | Runs |
| -------- | ----------- | ---- |
| Does it contain what it advertises? | [`check-image.sh`](check-image.sh) | inside the build, in a `check-<stage>` stage |
| Does the toolchain actually work? | [`smoke/`](smoke/) | inside the image, by bind-mount |

## The one rule

**No version number appears outside the [Dockerfile](../../../Dockerfile).**

`check-image.sh` runs inside a `check-<stage>` build stage, which inherits the stage it checks. Its
expectations *are* `${CMAKE_VERSION}`, `${GCC_VERSIONS}`, `${OHMYZSH_COMMIT}` - collected from the
Dockerfile's own `ARG`s into `/expected.env` by the `check-expectations` stage, which is the one
place listing what gets checked. Nothing parses the Dockerfile, nothing re-runs the Renovate manager
regexes, and bumping a pin needs no edit here.

An `ARG` that arrived empty would make every assertion built on it pass vacuously, so the script
refuses to run rather than report a false green.

## Why it runs inside the build

Because that is the cheap place. Any host-side check needs the image in a daemon first - `--load`
for nine images is minutes, a registry pull is worse - and that cost is what keeps a check out of
the publish path. Inside the build the layers are already in the builder's cache, so the whole thing
costs one `RUN`.

It also inspects the right filesystem: the published one, after every purge, `--auto-remove` and
snapshot `dist-upgrade`, which is exactly where a package that was installed can stop being there.

Keeping the assertions in a *separate* stage rather than appending them to the stages themselves is
what stops an edit to `check-image.sh` from invalidating the toolchain layers of every image below
it. And because CI pushes `<stage>` rather than `check-<stage>`, nothing here reaches a released
digest.

## Files

| File | Runs | Purpose |
| ---- | ---- | ------- |
| `check-image.sh` | in a `check-<stage>` stage | Every content assertion. Restricted to what `runtime` ships: bash, coreutils, `ldconfig`, `dpkg-query` |
| `smoke/cxx23.cpp` | compiled in the image | `std::print`, `std::expected`, deducing `this`, `constexpr std::vector` |
| `smoke/run.sh` | in the image | Compiles and runs the payload with every default compiler |
| `smoke/cross.sh` | in the image | Cross-compiles the payload `-static` for each triplet |
| `smoke/runtime-abi.cpp` | compiled in `build`, run in `runtime` | A `std::string` past SSO plus a thrown exception - the libstdc++ and unwinder path |
| `run-cross.sh` | on the host | Drives `cross.sh`, then executes the artifacts under qemu |
| `run-runtime-abi.sh` | on the host | Spans two images, so it cannot live in a per-stage loop |

The smoke tests reach an image by **bind mount**, never by `COPY`: `scripts/details` is excluded
from the build context in [`.dockerignore`](../../../.dockerignore). `check-image.sh` is the single
negated exception there, because the `check-<stage>` stages `COPY` it in.

## Usage

```bash
# the whole content check, one command - no host script, no --load
docker build --target check-build .

# the same for any stage
docker build --target check-runtime .
docker build --target check-dev --build-arg BINUTILS_TARGETS='aarch64-linux-gnu' .

# the smoke tests, against an image you already built
docker run --rm --volume "${PWD}/scripts/details/tests:/opt/cpp-toolchain-tests:ro" \
    cpp-toolchain:build bash /opt/cpp-toolchain-tests/smoke/run.sh
bash scripts/details/tests/run-cross.sh cpp-toolchain:build-cross
bash scripts/details/tests/run-runtime-abi.sh cpp-toolchain:build cpp-toolchain:runtime
```

CI builds `check-<stage>` in [`docker-build.yml`](../../../.github/workflows/docker-build.yml)
instead of `<stage>` - that job was already building those layers and pushing nothing, so the check
costs only the `RUN` - and again in
[`docker-publish.yml`](../../../.github/workflows/docker-publish.yml) before each push, so a stage
that lost a package never reaches a registry.

## Things worth knowing before changing this

- **`GCC_VERSIONS` is a selector, not a version.** It accepts `15`, `9 11 13`, `>=13`, `all`,
  `latest` and `latest-stable`; only bare-numeric tokens name a major that must be installed. The
  rest resolve against the archive during the build, so this file cannot know what they produced and
  does not pretend to - see `selector_majors`.
- **More than one compiler major is installed even at `GCC_VERSIONS=15`**, because Ubuntu's own
  `g++-13` arrives transitively. Nothing here ever asserts that a major is *absent*. What it does
  assert is that the unversioned driver resolves to a requested one - a broken `update-alternatives`
  registration is the failure nothing else would notice.
- **Both families resolve the same way, on purpose.** `gcc.sh` and `llvm.sh` each register a version
  at a priority equal to its own major, so the unversioned `g++` and `clang++` both point at the
  newest of their family. `llvm.sh` used to give LLVM's `latest-stable` a flat `100`, which made
  `--versions='21 22'` resolve `clang++` to 21; that is what the assertion would now catch.
- **The `build` / `static-analysis` boundary is asserted on both halves.** `build` runs
  `llvm.sh --mode=minimalistic`, which neither installs nor registers the analysis tooling, so the
  check requires `clang-tidy-<major>` to be *absent as a package* **and** `clang-tidy` to be off
  `PATH`. The package half is the one that matters: a mode that silently fell back to the upstream
  `all` set would still pass the command-level check on its own.
- **The compiler runtimes are asserted separately from the compilers.** `libc++-<N>-dev`,
  `libomp-<N>-dev` and `libclang-rt-<N>-dev` are what make `-stdlib=libc++`, `-fopenmp` and
  `-fsanitize=...` work; every `llvm.sh --mode` keeps them precisely because they are compiler
  capabilities rather than tools. Nothing else here would notice them going missing - `clang++`
  itself would still run, and the failure would surface as a link error in someone's project.
- **The cross toolchain's version is pinned by nothing.** `binutils.sh` installs unversioned
  `g++-<triplet>` from the snapshot-pinned archive, so it is the distro's GCC. Only presence is
  asserted - and via `dpkg`, because Debian multiarch ships `/usr/bin/x86_64-linux-gnu-g++` in every
  image as an alias for the native compiler, so a filesystem check reports that triplet as present
  in a lean image with no cross toolchain at all.
- **`libstdc++6` carries a load-bearing assertion.** `runtime` drops the snapshot pin specifically so
  `ppa:ubuntu-toolchain-r/test` can win. If that regresses, the library falls back to the Ubuntu
  archive build and every binary the pinned GCC produces fails to load. The check is that its major
  is `>=` the highest pinned GCC major.
- **`runtime` is asserted to have no libc++**, even though `build` can link against it. That is the
  documented contract (README package matrix); the assertion exists so it stays a decision rather
  than drifting.
- **A failing assertion is a finding, not a reason to loosen it.** If an image does not contain what
  the Dockerfile says it does, that is the bug this exists to surface.
