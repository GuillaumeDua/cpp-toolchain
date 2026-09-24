# Repository tooling

Implementation details of *this* repository - unlike the [toolchain installers](../install/README.md) next door, these are not reusable elsewhere: they parse this repo's [Dockerfile](../../Dockerfile), [renovate.json](../../renovate.json) and `releases/` records.

| Script | Purpose |
| ------ | ------- |
| `check-dependencies-pins.py` | Asserts every global `ARG` is pinned to a single exact version, matched by a [renovate.json](../../renovate.json) manager, and not shadowed by a stage-local re-declaration |
| `check-action-pins.py` | Asserts every third-party GitHub Action a workflow or composite action uses is pinned to a commit digest, carrying the tag it was pinned from |
| `render-manifest.py` | Renders those pins as the markdown "what's inside" note used for the GitHub release description, or (`--bumps-yaml`) as the `bumps:` mapping of a promotion record. `--versions` fills the `Installed` and `Stage introducing` columns from a record and diffs both against the previous one, `--collected` turns one collector output per published stage into those mappings, `--date` stamps the heading; `--changelog` splices a merged-pull-request list into the same marked region; `--replace-region` edits a release body around those markers, refusing an unbalanced pair |
| `shared.sh` | One body per helper the scripts under [`scripts/`](../) share, sourced by all of them. The copies published per release are composed from it, not committed. Also names the two things a caller defines itself, `retry_backoff_seconds` and `error()` |
| `compose-standalone.py` | Inlines `shared.sh` into a script that sources it, producing the self-contained copy published per release. Only the helpers a script calls are inlined, closed over the library's own calls. Refuses a script that both sources the library and redeclares one of its helpers |
| `check-release-file.py` | The single definition of the `releases/v*.yaml` schema, of the version grammar (which tags are releases and how they order), of the collected-key grammar, of the canonical stage and registry lists, and of the promotion plan derived from a record |
| `cxx-toolchain-versions.sh` | Runs *inside* a published image and reports what it carries where a pin cannot say it - the distribution point release and archive snapshot, both compilers, all three standard library implementations with their ABI levels, and the toolchain commands - as `key=value` lines. See [Tags & versioning](../../README.md#whats-inside-a-given-tag). Composes [`gcc.sh`/`llvm.sh --list-installed`](../install/), [`cxx-stdlibs.sh`](../checks/cxx-stdlibs.sh) and [`c-stdlibs.sh`](../checks/c-stdlibs.sh) |
| `build-stages.sh` | Builds a list of Dockerfile stages, one buildx invocation each. Owns the buildx flags and the layer cache scopes for both [docker-build](../../.github/workflows/docker-build.yml) and [docker-publish](../../.github/workflows/docker-publish.yml) |
| `smoke-test.sh` | Runs *inside* a candidate image - compiles and runs a C++23 hello world with both default compilers. Bind-mounted and executed by [release-candidate-check.yml](../../.github/workflows/release-candidate-check.yml) |
| `test-release-tooling.py` | Covers `render-manifest.py` and `check-release-file.py`, the two scripts that write release pages and the `bumps:` half of a promotion record. Inline fixtures, so a pin bump never turns a test red |

Everything here that runs at all runs from the **repository root**: the Python defaults are paths relative to the working directory, and `build-stages.sh` uses it as the build context.
`smoke-test.sh` and `cxx-toolchain-versions.sh` are the exceptions: they run inside an image, over a bind-mounted `scripts/`, not here.
`shared.sh` runs nowhere - it is sourced, or inlined into a published copy.

```bash
python3 scripts/details/check-dependencies-pins.py               # exits non-zero and reports every violation
python3 scripts/details/compose-standalone.py scripts/install/gcc.sh  # the published, self-contained gcc.sh
python3 scripts/details/check-action-pins.py                     # every `uses:` is a commit digest
python3 scripts/details/test-release-tooling.py                  # the release tooling's own tests
python3 scripts/details/render-manifest.py --tag v1.2            # diffed against the newest release before it
python3 scripts/details/check-release-file.py releases/v1.2.yaml # schema only, offline
bash    scripts/details/cxx-toolchain-versions.sh                 # the host's C++ toolchain, key=value
bash    scripts/details/build-stages.sh --help                   # the buildx driver's options
```

`check-dependencies-pins.py`, `check-action-pins.py` and `test-release-tooling.py` are three of the [build gate](../../.github/workflows/docker-build.yml)'s first four steps, so running them before pushing saves a round trip.
The fourth composes every standalone script and runs it in an empty directory, which is the promise those files make.
`check-release-file.py` backs the [release process](../../docs/RELEASE_PROCESS.md) - see it for what a promotion record is.
The workflows read its stage lists and pass them to `build-stages.sh`, which reads its registry list itself.

`check-dependencies-pins.py` and `render-manifest.py` read the manager regexes out of `renovate.json` rather than restating them,  
so what Renovate tracks, what the guard enforces, and what the release note lists cannot drift apart.  
`UBUNTU_SNAPSHOT` is the single exempt pin - no datasource can enumerate snapshot timestamps, so [ubuntu-snapshot.yml](../../.github/workflows/ubuntu-snapshot.yml) bumps it instead.
