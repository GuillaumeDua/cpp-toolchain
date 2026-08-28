# Documentation site

Every markdown file in the repository - [README.md](../../README.md), [HOW_TO_CONTRIBUTE.md](../../HOW_TO_CONTRIBUTE.md), [docs/](..) and each directory's own `README.md` - is rendered by [doxygen](https://www.doxygen.nl) and published to <https://guillaumedua.github.io/cpp-toolchain>.
A new document is published by existing: there is no page list to keep in step.

[.github/workflows/documentation.yml](../../.github/workflows/documentation.yml) publishes it on every push to `main`, and on manual dispatch.
It never runs on a pull request: documentation does not gate a merge.
GitHub serves the `gh-pages` branch the workflow pushes to, which is a repository setting (*Settings* -> *Pages* -> *Source*) and not something the workflow can establish for itself.

## Rendering it locally

```bash
bash docs/details/generate.sh   # -> docs/output/index.html
```

Prerequisites are `curl`, `tar`, `awk`, and `python3` for the link filter.
Doxygen and the [doxygen-awesome-css](https://github.com/jothepro/doxygen-awesome-css) theme are downloaded on first run and cached in `.cache/`, which CI restores between runs, so neither is committed and neither has to be installed.
Doxygen comes from [scripts/install/doxygen.sh](../../scripts/install/doxygen.sh), the same installer the images use, pointed at `.cache/` with `--prefix`.
A doxygen already on `PATH` is used as it is when it is exactly the pinned version, and ignored otherwise.

Both versions are pinned, and `--doxygen-version` / `--doxygen-awesome-version` override either one:

| Pin | Where | Why there |
| --- | ----- | --------- |
| doxygen | `ARG DOXYGEN_RELEASE` in the [Dockerfile](../../Dockerfile) | The site renders with the doxygen the `documentation` image ships, so there is one version rather than two |
| doxygen-awesome-css | `DOXYGEN_AWESOME_PIN` in [generate.sh](generate.sh) | The theme is installed in no image, so it has no `ARG` to hang off |

Doxygen **1.17.0** is the minimum, and the script refuses to run below it: earlier releases render a `mermaid` fence as a plain code block rather than a diagram ([doxygen PR #12069](https://github.com/doxygen/doxygen/pull/12069)).

## When something is wrong

Doxygen exits 0 on almost everything, including a dead link and an `INPUT_FILTER` that cannot run, so neither the script nor the workflow trusts its exit status alone.

- **A render that produced no pages fails the script.** That is what a broken link filter looks like, and publishing it would empty the site.
- **Everything doxygen reports goes to one issue**, titled *documentation: doxygen diagnostics*, rewritten on each run and closed again once a render comes back clean.
  `--diagnostics <file>` is how the workflow collects them; without it they go to stderr.

One warning is subtracted before any of that: doxygen cannot pair the backtick opening the linker error quoted in [scripts/checks/README.md](../../scripts/checks/README.md), because its pre-scanner does not recognize a fence nested in a blockquote.
The page renders correctly, and escaping the backtick is not an option - CommonMark does not process escapes inside a code block, so GitHub would show the backslash.

## The pieces

| File | Role |
| ---- | ---- |
| [generate.sh](generate.sh) | Fetches doxygen and the theme, builds the HTML header, renders `docs/output/` |
| [Doxyfile](Doxyfile) | The settings that differ from doxygen's defaults, each with the reason it is set |
| [github-links.py](github-links.py) | `INPUT_FILTER`: rewrites links to non-markdown files as absolute GitHub URLs |
| [theme-scripts.html](theme-scripts.html) | The theme's script tags, injected into the generated header |

## Where the site differs from GitHub

A link to the Dockerfile, to an install script or to a directory leaves the site for GitHub, because the site holds rendered pages and nothing else.
Links between markdown files stay inside it.
