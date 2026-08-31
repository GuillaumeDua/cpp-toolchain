# Repository tooling

Implementation details of *this* repository - unlike the [toolchain installers](../install/README.md) next door, these are not reusable elsewhere: they parse this repo's [Dockerfile](../../Dockerfile), [renovate.json](../../renovate.json) and `releases/` records.

| Script | Purpose |
| ------ | ------- |
| `check-dependencies-pins.py` | Asserts every global `ARG` is pinned to an exact version, matched by a [renovate.json](../../renovate.json) manager, and not shadowed by a stage-local re-declaration |
| `render-manifest.py` | Renders those pins as the markdown "what's inside" table used for the GitHub release description, or (`--bumps-yaml`) as the `bumps:` mapping of a promotion record |
| `check-release-file.py` | The single definition of the `releases/v*.yaml` schema, of the canonical stage lists, and of the promotion plan derived from a record |
| `smoke-test.sh` | Runs *inside* a candidate image - compiles and runs a C++23 hello world with both default compilers. Bind-mounted and executed by [release-candidate-check.yml](../../.github/workflows/release-candidate-check.yml) |

The three Python scripts run from the **repository root** - their default paths are relative to the working directory.
`smoke-test.sh` is the exception: it runs inside the image under test, not here.

```bash
python3 scripts/details/check-dependencies-pins.py               # exits non-zero and reports every violation
python3 scripts/details/render-manifest.py --tag v1.2            # diffed against the newest release before it
python3 scripts/details/check-release-file.py releases/v1.2.yaml # schema only, offline
```

`check-dependencies-pins.py` is the [build gate](../../.github/workflows/docker-build.yml)'s first step, so running it before pushing saves a round trip.
`check-release-file.py` backs the [release process](../../docs/RELEASE_PROCESS.md) - see it for what a promotion record is.

The first two read the manager regexes out of `renovate.json` rather than restating them,  
so what Renovate tracks, what the guard enforces, and what the release note lists cannot drift apart.  
`UBUNTU_SNAPSHOT` is the single exempt pin - no datasource can enumerate snapshot timestamps, so [ubuntu-snapshot.yml](../../.github/workflows/ubuntu-snapshot.yml) bumps it instead.
