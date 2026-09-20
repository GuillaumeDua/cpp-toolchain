# How to contribute

Thanks for helping improve **cpp-toolchain**.  

This document covers the contribution workflow: how changes get in, what the CI gate expects, and how images get published.

## The workflows

There is a hard split between **building** (gate, runs on every PR) and **publishing** (pushes tags, only ever from `main`):

| Workflow | Trigger | What it does | Pushes? |
| -------- | ------- | ------------ | :-----: |
| [docker-build](.github/workflows/docker-build.yml) | every PR to `main`, every push to `main` | builds the normal variant in full and the cross-arch `build`, then runs the [images validation gate](docs/IMAGES_VALIDATION.md); a push to `main` also builds the cross-arch `static-analysis` / `documentation` / `dev` | ❌ |
| [docker-publish](.github/workflows/docker-publish.yml) | GitHub **release** (major), merged **candidate PR** (minor), twice-monthly rc schedule, manual dispatch | builds rcs/majors, promotes minors, pushes tags to Docker Hub + GHCR | ✅ |
| [release-candidate-check](.github/workflows/release-candidate-check.yml) | every PR to `main` (no-op unless a promotion record is touched) | validates the promotion record and smoke-tests the candidate image by digest | ❌ |
| [documentation](.github/workflows/documentation.yml) | every push to `main`, manual dispatch | renders the repository's markdown and publishes it to the `gh-pages` branch ([docs/details](docs/details/README.md)) | ❌ |
| [ubuntu-snapshot](.github/workflows/ubuntu-snapshot.yml) | monthly schedule (25th), manual dispatch | opens a PR moving the Ubuntu archive snapshot forward | ❌ |

What those workflows share lives in [.github/actions/](.github/actions/) as composite actions:
buildx setup, registry login, promotion-record identification, and the sticky issue the two report steps share.

> [!IMPORTANT]
> **PR validation**
>
> Every PR to `main` must still build all five stages of the normal variant, plus the cross-arch toolchain and its validation ([docker-build](.github/workflows/docker-build.yml)); publishing is a separate workflow that refuses to push anything whose commit is not contained in `main`.

## Opening a pull request

1. Branch off `main` (branch names follow `<issue-number>-<short-description>`, e.g. `19-add-arm64-support`).
2. Make your change.
   If you touch the [Dockerfile](Dockerfile) or the [scripts](scripts/),  
   build the affected stages locally first (see below) - a broken layer fails the gate for everyone.
3. Open a PR against `main`.
   The [docker-build](.github/workflows/docker-build.yml) gate runs automatically.
4. Keep the PR green: every stage the gate builds must build before it can merge.

The gate is deliberately **not** path-filtered - it is a required status check, so it runs on every PR (a path-filtered workflow that never runs would leave the PR waiting forever on a check that never reports).  
When the Dockerfile and scripts are untouched the GitHub Actions cache makes it a near-no-op.  
Only a push to `main` writes that cache, so a PR replays the layers the last merge exported, and the first PR after a snapshot bump pays for a cold build.  
Nothing is pushed, no registry credentials are needed, and the gate therefore also works for PRs coming from forks (which have no access to secrets).

## What the build gate checks

[docker-build](.github/workflows/docker-build.yml) builds, in dependency order on a single buildx builder, both image variants:

- **normal / lean** (`BINUTILS_TARGETS=''`): `runtime`, `build`, `static-analysis`, `documentation`, `dev`
- **cross-arch** (`BINUTILS_TARGETS='common'`, the triplets listed in [binutils.sh](scripts/install/binutils.sh)): `build` on a PR, and `static-analysis`, `documentation`, `dev` as well on a push to `main`

`runtime` carries no toolchain, so it has no cross variant.
A break in either variant fails the gate.

`BINUTILS_TARGETS` is consumed at the tail of `build`, so changing it re-parents every stage above it: the cross-arch `static-analysis` / `documentation` / `dev` can hit no cache and reinstall their packages in full, for package sets the normal variant has already built.
A PR therefore gates the cross toolchain itself, through `build` and `validate-build`.
Build the three locally, as below, when you change what they install.

It then runs the **images validation gate** - the `validate-build` and `validate-runtime` stages, which assert that every toolchain package still comes from the repository that owns it, and that a binary compiled in `build` still runs on `runtime`.  
Both are throwaway stages built on layers the job already has, so they cost a cache hit plus their own `RUN`.
See [docs/IMAGES_VALIDATION.md](docs/IMAGES_VALIDATION.md).

Reproduce it locally before pushing (context is the repo root).
This is the driver the gate runs, with the cache flags off:

```bash
bash scripts/details/build-stages.sh --variant normal --cache none \
  $(python3 scripts/details/check-release-file.py --print-stages normal)

bash scripts/details/build-stages.sh --variant cross --cache none \
  $(python3 scripts/details/check-release-file.py --print-stages cross)
```

`build-stages.sh` calls `docker buildx build`. Without buildx, drive `docker build` over the same stage lists:

```bash
for stage in $(python3 scripts/details/check-release-file.py --print-stages normal); do
  docker build --target "$stage" .
done

for stage in $(python3 scripts/details/check-release-file.py --print-stages cross); do
  docker build --target "$stage" --build-arg BINUTILS_TARGETS=common .
done
```

The heavy `build` layer is produced once and reused by `static-analysis` / `documentation` / `dev`, so a full local run is cheaper than five independent builds.

## The repository's dev container

[.devcontainer/](.devcontainer/) is for working **on** cpp-toolchain, not for consuming it.
Its [`docker-compose.yaml`](.devcontainer/docker-compose.yaml) names no registry: it builds the `dev` target from the repo-root [Dockerfile](Dockerfile) and mounts the checkout at `/workspace`, so **Reopen in Container** gives you a from-source environment with your working tree in it, at the cost of a full local build.

Consuming the published images needs none of that - one `devcontainer.json` with an `image` key, in [Using the images](docs/IMAGES.md#visual-studio-code---dev-container).

The local build above builds every stage; [Build your own image](docs/IMAGES.md#build-your-own-image) builds a single customised one. Different jobs, so neither replaces the other.

## How images get published

Publishing is [docker-publish](.github/workflows/docker-publish.yml) - a **separate** workflow that contributors never trigger from a PR:

- The twice-monthly **rc schedule** and manual dispatch cut a **release candidate** (`v1.2-rc.1`) and open a candidate PR; it never moves `latest`.
- A **minor** (`v1.1`, `v1.2`, ...) ships when the maintainer **merges that candidate PR**: the rc's image digests are re-tagged, so the release is byte-identical to the rc that was validated - no rebuild.
- A GitHub **release** cut by hand from `main` publishes a **major** (`v<major>.0`, e.g. `v2.0`) plus the `latest` alias.
- The scheduled rc **publishes nothing when nothing changed**: an unchanged tree has nothing new to ship, so no release is cut just because a date arrived.
- Images go to both **Docker Hub** and **GHCR**.

The full release procedure (promotion, urgent fixes, rollback, failure modes) is in [docs/RELEASE_PROCESS.md](docs/RELEASE_PROCESS.md) - the cadence is stated there and nowhere else.

Release notes are composed by [scripts/details/render-manifest.py](scripts/details/render-manifest.py): the versions a release pins and what moved since the previous one, read from the Dockerfile's `ARG`s; what the images actually installed where a pin cannot say, read from the images themselves; then the pull requests merged since that release.
The second half is a plain list of PR titles, so the title you give a PR is what a release note shows.
What a pin does and does not fix is in [Tags & versioning](README.md#whats-inside-a-given-tag).

Guards protecting the registries:

- **Tag format** - a hand-cut release tag that is not a major (`v<major>.0`) is rejected before anything is published: minors ship by merging a candidate PR, never by cutting a release.
- **Publish from `main` only** - a release or tag can be cut from any commit, so the workflow verifies the built commit is contained in `origin/main` (`git merge-base --is-ancestor`) and **refuses to publish** otherwise.
  This covers releases, the schedule (always `main`) and manual dispatch (could fire from any branch).
- **Promotion by digest** - a promotion re-tags the digests recorded in `releases/v*.yaml` and fails if any tag moved since the rc was built, so what ships is exactly what was validated.

See [Tags & versioning](README.md#tags--versioning) for the full tag scheme.

## Related docs

- [README.md](README.md) - the images themselves: stages, features, tags, what each contains.
- [scripts/install/README.md](scripts/install/README.md) - the standalone `cmake.sh` / `gcc.sh` / `llvm.sh` / `binutils.sh` options.
- [releases/README.md](releases/README.md) - the promotion record behind each shipped release: the rc it came from, the commit built, and every stage's digest.
- [scripts/details/README.md](scripts/details/README.md) - the repository's own tooling: pin guard, release-note renderer, promotion-record schema, smoke test.
- [docs/details/README.md](docs/details/README.md) - how this documentation is rendered and published, and how to preview it locally.
