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

Doxygen **1.18.0** is the minimum, and the script refuses to run below it: 1.17.0 renders the text of every link carrying a `#fragment` twice ([doxygen issue #12155](https://github.com/doxygen/doxygen/issues/12155)), and releases before it render a `mermaid` fence as a plain code block rather than a diagram ([doxygen PR #12069](https://github.com/doxygen/doxygen/pull/12069)).

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
| [github-links.py](github-links.py) | `INPUT_FILTER`: rewrites links to non-markdown files as absolute GitHub URLs, and images as `raw` ones |
| [theme-scripts.html](theme-scripts.html) | The theme's script tags, injected into the generated header |
| [site.css](site.css) | Overrides on top of doxygen-awesome, loaded last |
| [favicon.svg](favicon.svg) | The browser-tab icon, shipped by `HTML_EXTRA_FILES` and linked from `theme-scripts.html` |
| [logo.svg](logo.svg) | The mark [README.md](../../README.md) opens with |

## Where the site differs from GitHub

A link to the Dockerfile, to an install script or to a directory leaves the site for GitHub, because the site holds rendered pages and nothing else.
Links between markdown files stay inside it.

Three things do not carry over:

- **A pipe inside a table cell** is written `<code>a\|b</code>`, not `` `a\|b` ``.  
  Doxygen leaves the backslash visible inside a code span, so the cell has to be a raw `<code>`, where angle brackets in turn need `&lt;` and `&gt;`: GitHub reads `<directory>` as a tag and drops it.  
  A double dash inside that `<code>` is written `\-\-`, because doxygen turns a bare `--` there into an en-dash.
- **A heading repeated across two pages** gets a numbered anchor here, `see-also-1` against GitHub's `see-also`, because doxygen scopes section labels to the whole project rather than to a page.  
  The number follows render order, so nothing should deep-link to a repeated heading.
- **The search box covers titles only.** Doxygen indexes page and section titles for markdown input, not body text.

An image is the one relative target that reaches GitHub as `raw.githubusercontent.com` rather than `blob`, since a page wrapped around the bytes is not what an `<img>` can use.
