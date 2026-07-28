# How to contribute

Thanks for helping improve **cpp-toolchain**.  

This document covers the contribution workflow: how changes get in, what the CI gate expects, and how images get published.

## The two workflows

There is a hard split between **building** (gate, runs on every PR) and **publishing**
(pushes tags, only ever from `main`):

| Workflow | Trigger | What it does | Pushes? |
| -------- | ------- | ------------ | :-----: |
| [docker-build](.github/workflows/docker-build.yml) | every PR to `main`, every push to `main` | builds all stages in both variants | ❌ |
| [docker-publish](.github/workflows/docker-publish.yml) | GitHub **release**, monthly (minor) and twice-monthly (rc) schedules, manual dispatch | builds and pushes tags to Docker Hub + GHCR | ✅ |
| [ubuntu-snapshot](.github/workflows/ubuntu-snapshot.yml) | monthly schedule (25th), manual dispatch | opens a PR moving the Ubuntu archive snapshot forward | ❌ |

> [!IMPORTANT] PR validation
> Every PR to `main` must still build all stages in both the normal and cross-arch variants ([docker-build](.github/workflows/docker-build.yml)); publishing is a separate workflow that refuses to push anything whose commit is not contained in `main`.

## Opening a pull request

1. Branch off `main` (branch names follow `<issue-number>-<short-description>`, e.g. `19-add-arm64-support`).
2. Make your change. If you touch the [Dockerfile](Dockerfile) or the
   [scripts](scripts/), build the affected stages locally first (see below) -
   a broken layer fails the gate for everyone.
3. Open a PR against `main`. The [docker-build](.github/workflows/docker-build.yml) gate runs automatically.
4. Keep the PR green: **all** stages must build in **both** variants before it can merge.

The gate is deliberately **not** path-filtered - it is a required status check, so it runs on
every PR (a path-filtered workflow that never runs would leave the PR waiting forever on a check
that never reports). When the Dockerfile and scripts are untouched the GitHub Actions cache makes
it a near-no-op. Nothing is pushed, no registry credentials are needed, and the gate therefore also
works for PRs coming from forks (which have no access to secrets).

## What the build gate checks

[docker-build](.github/workflows/docker-build.yml) builds, in dependency order on a single buildx
builder, every stage in **both** image variants:

- **normal / lean** (`BINUTILS_TARGETS=''`): `runtime`, `build`, `static-analysis`, `documentation`, `dev`
- **cross-arch** (`BINUTILS_TARGETS='x86-64-linux-gnu aarch64-linux-gnu arm-linux-gnueabihf riscv64-linux-gnu'`): `build`, `static-analysis`, `documentation`, `dev`

`runtime` carries no toolchain, so it has no cross variant. A break in either variant fails the gate.

Reproduce it locally before pushing (context is the repo root):

```bash
# normal / lean variant - all five stages
for stage in runtime build static-analysis documentation dev; do
  docker build --target "$stage" .
done

# cross-arch variant - the four toolchain stages
CROSS_TARGETS='x86-64-linux-gnu aarch64-linux-gnu arm-linux-gnueabihf riscv64-linux-gnu'
for stage in build static-analysis documentation dev; do
  docker build --target "$stage" --build-arg "BINUTILS_TARGETS=${CROSS_TARGETS}" .
done
```

The heavy `build` layer is produced once and reused by `static-analysis` / `documentation` / `dev`,
so a full local run is cheaper than five independent builds.

## How images get published

Publishing is [docker-publish](.github/workflows/docker-publish.yml) - a **separate** workflow that
contributors never trigger from a PR:

- A GitHub **release** cut from `main` publishes a **major** (`v<major>.0`, e.g. `v2.0`) plus the `latest` alias.
- The **monthly schedule** (1st, 5am UTC) cuts the next **minor** (`v1.1`, `v1.2`, ...) and moves `latest` - the workflow creates that release itself.
- The **twice-monthly schedule** (8th and 22nd, 4am UTC) and manual dispatch cut a **pre-release** (`v1.2-rc.1`); it never moves `latest`, and its image tags are pruned once the minor ships.
- Both scheduled channels **publish nothing when nothing changed**: every version is pinned, so an unchanged commit would rebuild to an identical image.
- Images go to both **Docker Hub** and **GHCR**.

Release notes are generated from the Dockerfile's pinned `ARG`s by
[scripts/render-manifest.py](scripts/render-manifest.py), so each release states exactly what it
contains and what moved since the previous one.

Two guards protect the registries:

- **Tag format** - a release tag that is not `v<major>.<minor>` is rejected before anything is published.
- **Publish from `main` only** - a release or tag can be cut from any commit, so the workflow verifies the
  built commit is contained in `origin/main` (`git merge-base --is-ancestor`) and **refuses to publish**
  otherwise. This covers releases, the schedule (always `main`) and manual dispatch (could fire from any branch).

See [Tags & versioning](README.md#tags--versioning) for the full tag scheme.

## Related docs

- [README.md](README.md) - images, features, build arguments, cross-architecture compilation.
- [scripts/README.md](scripts/README.md) - the standalone `cmake.sh` / `gcc.sh` / `llvm.sh` / `binutils.sh` options.
