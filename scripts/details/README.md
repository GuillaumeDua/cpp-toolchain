# Repository tooling

Implementation details of *this* repository - unlike the [toolchain installers](../install/README.md)
next door, these are not reusable elsewhere: they parse this repo's [Dockerfile](../../Dockerfile),
[renovate.json](../../renovate.json) and `releases/` records.

| Script | Purpose |
| ------ | ------- |
| `check-dependencies-pins.py` | Asserts every global `ARG` is pinned to an exact version, matched by a [renovate.json](../../renovate.json) manager, and not shadowed by a stage-local re-declaration |
| `render-manifest.py` | Renders those pins as the markdown "what's inside" table used for the GitHub release description, or (`--bumps-yaml`) as the `bumps:` mapping of a promotion record |
| `check-release-file.py` | The single definition of the `releases/v*.yaml` schema, of the canonical stage lists, and of the promotion plan derived from a record |
| [`tests/`](tests/README.md) | Image verification: `check-image.sh` asserts a built image contains the pinned versions, from inside a `check-<stage>` build stage; `smoke/` asserts the toolchain works |

All of them run from the **repository root** - their default paths are relative to the working
directory:

```bash
python3 scripts/details/check-dependencies-pins.py                 # exits non-zero and reports every violation
python3 scripts/details/render-manifest.py --tag v1.2 --previous-ref v1.1
python3 scripts/details/check-release-file.py releases/v1.2.yaml   # schema only, offline
docker build --target check-build .                                # build `build`, then assert its contents
```

`check-dependencies-pins.py` is the [build gate](../../.github/workflows/docker-build.yml)'s first
step, so running it before pushing saves a round trip. `check-release-file.py` backs the
[release process](../../docs/RELEASE_PROCESS.md) - see it for what a promotion record is.

The pin readers - `check-dependencies-pins.py` and `render-manifest.py` - read the manager regexes
out of `renovate.json` rather than restating them, so what Renovate tracks, what the guard enforces
and what the release note lists cannot drift apart. `tests/check-image.sh` needs no reader at all:
it runs inside the build, where the pins are already in scope as `ARG`s.  
`UBUNTU_SNAPSHOT` is the single exempt pin - no datasource can enumerate snapshot timestamps, so
[ubuntu-snapshot.yml](../../.github/workflows/ubuntu-snapshot.yml) bumps it instead.
