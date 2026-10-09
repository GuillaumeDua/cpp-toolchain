# Repository tooling

Implementation details of *this* repository - unlike the [toolchain installers](../install/README.md) next door, these are not reusable elsewhere: they parse this repo's [Dockerfile](../../Dockerfile), [renovate.json](../../renovate.json) and `releases/` records.

## host/

Run from the **repository root**: the Python defaults are paths relative to the working directory,
and `build-stages.sh` uses it as the build context.

| Script | Purpose |
| ------ | ------- |
| `check_dependencies_pins.py` | Asserts every global `ARG` is pinned to a single exact version, matched by a [renovate.json](../../renovate.json) manager, and not shadowed by a stage-local re-declaration |
| `check_action_pins.py` | Asserts every third-party GitHub Action a workflow or composite action uses is pinned to a commit digest, carrying the tag it was pinned from |
| `render_manifest.py` | Renders those pins as the markdown "what's inside" note used for the GitHub release description, or (`--bumps-yaml`) as the `bumps:` mapping of a promotion record. `--versions` adds the `Installed` and `Stage introducing` columns from a record and diffs both against the previous one, `--collected` turns one collector output per published stage into those mappings, `--date` stamps the heading; `--changelog` splices a merged-pull-request list into the same marked region; `--replace-region` edits a release body around those markers, refusing an unbalanced pair |
| `compose_standalone.py` | Inlines [`lib/shared.sh`](../lib/shared.sh) into a script that sources it, producing the self-contained copy published per release. Only the helpers a script calls are inlined, closed over the library's own calls. Refuses a script that both sources the library and redeclares one of its helpers. `--all` names each output for the directory it came from, which is the name a release attaches it under |
| `check_release_file.py` | The single definition of the `releases/v*.yaml` schema, of the version grammar (which tags are releases and how they order), of the collected-key grammar, of the canonical stage and registry lists, and of the promotion plan derived from a record |
| `build-stages.sh` | Builds a list of Dockerfile stages, one buildx invocation each. Owns the buildx flags and the layer cache scopes for both [docker-build](../../.github/workflows/docker-build.yml) and [docker-publish](../../.github/workflows/docker-publish.yml) |
| `test_release_tooling.py` | Covers the four scripts the release path depends on - `render_manifest.py`, `check_release_file.py`, `compose_standalone.py` and `check_dependencies_pins.py`. Inline fixtures, so a pin bump never turns a test red |

## image/

Run inside a container, over a bind-mounted `scripts/`, not here.

| Script | Purpose |
| ------ | ------- |
| `cxx-toolchain-versions.sh` | Runs *inside* a published image and reports what it carries where a pin cannot say it - the distribution point release and archive snapshot, both compilers, all three standard library implementations with their ABI levels, and the toolchain commands - as `key=value` lines. See [Tags & versioning](../../README.md#whats-inside-a-given-tag). Composes [`gcc.sh`/`llvm.sh --list-installed`](../install/), [`cxx-stdlibs.sh`](../checks/cxx-stdlibs.sh) and [`c-stdlibs.sh`](../checks/c-stdlibs.sh) |
| `smoke-test.sh` | Runs *inside* a candidate image - compiles and runs a C++23 hello world with both default compilers. Bind-mounted and executed by [release-candidate-check.yml](../../.github/workflows/release-candidate-check.yml) |

```bash
python3 scripts/internal/host/check_dependencies_pins.py               # exits non-zero and reports every violation
python3 scripts/internal/host/compose_standalone.py scripts/install/gcc.sh  # the published, self-contained install_gcc.sh
python3 scripts/internal/host/check_action_pins.py                     # every `uses:` is a commit digest
python3 scripts/internal/host/test_release_tooling.py                  # the release tooling's own tests
python3 scripts/internal/host/render_manifest.py --tag v1.2            # diffed against the newest release before it
python3 scripts/internal/host/check_release_file.py releases/v1.2.yaml # schema only, offline
bash    scripts/internal/image/cxx-toolchain-versions.sh          # the host's C++ toolchain, key=value
bash    scripts/internal/host/build-stages.sh --help                   # the buildx driver's options
```

`check_dependencies_pins.py`, `check_action_pins.py` and `test_release_tooling.py` are three of the [build gate](../../.github/workflows/docker-build.yml)'s first four steps, so running them before pushing saves a round trip.
The fourth composes every standalone script and runs it in an empty directory, which is the promise those files make.
`check_release_file.py` backs the [release process](../../docs/RELEASE_PROCESS.md) - see it for what a promotion record is.
The workflows read its stage lists and pass them to `build-stages.sh`, which reads its registry list itself.

`check_dependencies_pins.py` and `render_manifest.py` read the manager regexes out of `renovate.json` rather than restating them,  
so what Renovate tracks, what the guard enforces, and what the release note lists cannot drift apart.  
Two global `ARG`s carry no annotation: `UBUNTU_SNAPSHOT`, which no datasource can enumerate, so [ubuntu-snapshot.yml](../../.github/workflows/ubuntu-snapshot.yml) bumps it instead, and `TOOLCHAIN_TMP_DIR`, which is a staging path rather than a dependency.
