# Documentation site

Every markdown file in the repository - [README.md](../../README.md), [HOW_TO_CONTRIBUTE.md](../../HOW_TO_CONTRIBUTE.md), [docs/](..) and each directory's own `README.md` - is rendered by [doxygen](https://www.doxygen.nl) and published to <https://guillaumedua.github.io/cpp-toolchain>.
A new document is published by existing: there is no page list to keep in step.

[.github/workflows/documentation.yml](../../.github/workflows/documentation.yml) publishes it on every push to `main` that touches documentation, and renders it without publishing on pull requests.
GitHub serves the `gh-pages` branch the workflow pushes to, which is a repository setting (*Settings* -> *Pages* -> *Source*) and not something the workflow can establish for itself.

## Rendering it locally

```bash
bash docs/details/generate.sh   # -> docs/output/index.html
```

Doxygen and the [doxygen-awesome-css](https://github.com/jothepro/doxygen-awesome-css) theme are downloaded on first run and cached in `.cache/`, so neither is committed and neither has to be installed.
Both default to their latest upstream release; `--doxygen-version` and `--doxygen-awesome-version` pin either one.

Doxygen **1.17.0** is the minimum, and the script refuses to run below it: earlier releases render a `mermaid` fence as a plain code block rather than a diagram ([doxygen PR #12069](https://github.com/doxygen/doxygen/pull/12069)).

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

Doxygen is stricter than GitHub about a stray backtick, and reports the ones it cannot pair as a warning while still rendering the page correctly, so the build does not fail on warnings.
Reading them is still worth it: a genuinely broken cross-document link shows up the same way.
