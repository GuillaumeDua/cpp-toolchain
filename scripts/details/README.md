# Repository tooling

Implementation details of *this* repository - unlike the [toolchain installers](../install/README.md) next door, these are not reusable elsewhere: they parse this repo's [Dockerfile](../../Dockerfile), [renovate.json](../../renovate.json) and `releases/` records.

| Script | Purpose |
| ------ | ------- |
| `check-dependencies-pins.py` | Asserts every global `ARG` is pinned to an exact version, matched by a [renovate.json](../../renovate.json) manager, and not shadowed by a stage-local re-declaration |
| `check-action-pins.py` | Asserts every third-party GitHub Action a workflow or composite action uses is pinned to a commit digest, carrying the tag it was pinned from |
| `render-manifest.py` | Renders those pins as the markdown "what's inside" table used for the GitHub release description, or (`--bumps-yaml`) as the `bumps:` mapping of a promotion record. `--versions` adds what the images installed and diffs it against the previous record, `--collected` turns the collector output into that mapping; `--changelog` splices a merged-pull-request list into the same marked region; `--replace-region` edits a release body around those markers, refusing an unbalanced pair |
| `check-install-script-parity.py` | Asserts the helper functions copied between [`scripts/install/`](../install/) scripts are byte-identical, so the standalone guarantee does not cost silent divergence |
| `check-release-file.py` | The single definition of the `releases/v*.yaml` schema, of the version grammar (which tags are releases and how they order), of the canonical stage and registry lists, and of the promotion plan derived from a record |
| `cxx-toolchain-versions.sh` | Runs *inside* a published image and reports the C++ toolchain it carries - both compilers and both standard library implementations, with their ABI levels - as `key=value` lines. Only what a pin cannot say - see [Tags & versioning](../../README.md#whats-inside-a-given-tag). Composes [`gcc.sh`/`llvm.sh --list-installed`](../install/) and [`cxx-stdlibs.sh`](../checks/cxx-stdlibs.sh) |
| `build-stages.sh` | Builds a list of Dockerfile stages, one buildx invocation each. Owns the buildx flags and the layer cache scopes for both [docker-build](../../.github/workflows/docker-build.yml) and [docker-publish](../../.github/workflows/docker-publish.yml) |
| `smoke-test.sh` | Runs *inside* a candidate image - compiles and runs a C++23 hello world with both default compilers. Bind-mounted and executed by [release-candidate-check.yml](../../.github/workflows/release-candidate-check.yml) |
| `test-release-tooling.py` | Covers `render-manifest.py` and `check-release-file.py`, the two scripts that write release pages and the `bumps:` half of a promotion record. Inline fixtures, so a pin bump never turns a test red |

Everything here runs from the **repository root**: the Python defaults are paths relative to the working directory, and `build-stages.sh` uses it as the build context.
`smoke-test.sh` and `cxx-toolchain-versions.sh` are the exceptions: they run inside an image, over a bind-mounted `scripts/`, not here.

```bash
python3 scripts/details/check-dependencies-pins.py               # exits non-zero and reports every violation
python3 scripts/details/check-install-script-parity.py           # shared helpers, byte for byte
python3 scripts/details/check-action-pins.py                     # every `uses:` is a commit digest
python3 scripts/details/test-release-tooling.py                  # the release tooling's own tests
python3 scripts/details/render-manifest.py --tag v1.2            # diffed against the newest release before it
python3 scripts/details/check-release-file.py releases/v1.2.yaml # schema only, offline
bash    scripts/details/cxx-toolchain-versions.sh                 # the host's C++ toolchain, key=value
bash    scripts/details/build-stages.sh --help                   # the buildx driver's options
```

`check-dependencies-pins.py`, `check-install-script-parity.py`, `check-action-pins.py` and `test-release-tooling.py` are the [build gate](../../.github/workflows/docker-build.yml)'s first four steps, so running them before pushing saves a round trip.
`check-release-file.py` backs the [release process](../../docs/RELEASE_PROCESS.md) - see it for what a promotion record is.
The workflows read its stage lists and pass them to `build-stages.sh`, which reads its registry list itself.

`check-dependencies-pins.py` and `render-manifest.py` read the manager regexes out of `renovate.json` rather than restating them,  
so what Renovate tracks, what the guard enforces, and what the release note lists cannot drift apart.  
`UBUNTU_SNAPSHOT` is the single exempt pin - no datasource can enumerate snapshot timestamps, so [ubuntu-snapshot.yml](../../.github/workflows/ubuntu-snapshot.yml) bumps it instead.
