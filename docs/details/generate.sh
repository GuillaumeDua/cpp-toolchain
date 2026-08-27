#!/usr/bin/env bash

# Render the repository's markdown as the documentation site, into docs/output.
# .github/workflows/documentation.yml runs this and publishes the result to GitHub Pages.
#
# Neither doxygen nor the doxygen-awesome-css theme is committed: both are fetched here, latest release by default,
# and cached, so a re-run with nothing new to fetch goes straight to rendering.
# Nothing else is needed - no graphviz, and no Node.js, because mermaid diagrams render client-side.
#
# The HTML header is generated from the running doxygen's own template rather than committed as a file.
# A committed header is pinned to the doxygen version it was written for and silently loses whatever
# later versions add to it - which is how a $mermaidjs-less header would leave every diagram blank.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

readonly DOXYFILE="docs/details/Doxyfile"
readonly THEME_SCRIPTS="docs/details/theme-scripts.html"
readonly CACHE_DIR="docs/details/.cache"
readonly OUTPUT_DIR="docs/output"

# ```mermaid fences are rendered from doxygen 1.17.0 on (doxygen PR #12069); before that they come out as code blocks.
readonly DOXYGEN_MINIMUM_VERSION="1.17.0"

# --- arguments ---

doxygen_version=
doxygen_awesome_version=

usage() {
    cat <<'USAGE'
Usage: docs/details/generate.sh [--doxygen-version <version>] [--doxygen-awesome-version <version>]

Both default to the latest upstream release, and accept an optional leading `v`.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --doxygen-version)         doxygen_version="$2";         shift 2 ;;
        --doxygen-awesome-version) doxygen_awesome_version="$2";  shift 2 ;;
        -h|--help)                 usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# --- helpers ---

http_get() {
    if command -v curl &>/dev/null; then
        curl -fsSL "$1"
    else
        wget -qO- "$1"
    fi
}

github_latest_tag() {
    http_get "https://api.github.com/repos/$1/releases/latest" \
        | grep '"tag_name"' | head -1 \
        | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/'
}

# The lowest of the two arguments, per `sort -V`.
lowest_version() {
    printf '%s\n%s\n' "$1" "$2" | sort -V | head -1
}

# --- versions ---

# doxygen tags its releases Release_1_17_0.
if [[ -z "${doxygen_version}" ]]; then
    tag=$(github_latest_tag "doxygen/doxygen")
    doxygen_version="${tag#Release_}"
    doxygen_version="${doxygen_version//_/.}"
fi
doxygen_version="${doxygen_version#v}"

if [[ -z "${doxygen_awesome_version}" ]]; then
    doxygen_awesome_version=$(github_latest_tag "jothepro/doxygen-awesome-css")
fi
doxygen_awesome_version="${doxygen_awesome_version#v}"

if [[ "$(lowest_version "${doxygen_version}" "${DOXYGEN_MINIMUM_VERSION}")" != "${DOXYGEN_MINIMUM_VERSION}" ]]; then
    echo "doxygen ${doxygen_version} is below the required ${DOXYGEN_MINIMUM_VERSION}: mermaid diagrams would not render." >&2
    exit 1
fi

echo "doxygen ${doxygen_version} / doxygen-awesome-css ${doxygen_awesome_version}"

mkdir -p "${CACHE_DIR}"

# --- doxygen ---

# An installed doxygen is only reused when it is the exact version asked for,
# so the site never renders with something other than what this run reports.
doxygen_binary="doxygen"
if [[ "$(command -v doxygen &>/dev/null && doxygen --version | cut -d' ' -f1)" != "${doxygen_version}" ]]; then
    doxygen_binary="${CACHE_DIR}/doxygen-${doxygen_version}/bin/doxygen"

    if [[ ! -x "${doxygen_binary}" ]]; then
        echo "Downloading doxygen ${doxygen_version}..."
        http_get "https://github.com/doxygen/doxygen/releases/download/Release_${doxygen_version//./_}/doxygen-${doxygen_version}.linux.bin.tar.gz" \
            | tar xzf - -C "${CACHE_DIR}"
    fi
fi

# --- doxygen-awesome-css ---

readonly DOXYGEN_AWESOME_DIR="${CACHE_DIR}/doxygen-awesome"
readonly DOXYGEN_AWESOME_VERSION_FILE="${DOXYGEN_AWESOME_DIR}/.version"

# Only the files the Doxyfile and theme-scripts.html reference.
readonly DOXYGEN_AWESOME_FILES=(
    doxygen-awesome.css
    doxygen-awesome-sidebar-only.css
    doxygen-awesome-sidebar-only-darkmode-toggle.css
    doxygen-awesome-darkmode-toggle.js
    doxygen-awesome-paragraph-link.js
    doxygen-awesome-interactive-toc.js
)

if [[ "$(cat "${DOXYGEN_AWESOME_VERSION_FILE}" 2>/dev/null || true)" != "${doxygen_awesome_version}" ]]; then
    echo "Downloading doxygen-awesome-css ${doxygen_awesome_version}..."
    mkdir -p "${DOXYGEN_AWESOME_DIR}"
    for file in "${DOXYGEN_AWESOME_FILES[@]}"; do
        http_get "https://raw.githubusercontent.com/jothepro/doxygen-awesome-css/v${doxygen_awesome_version}/${file}" \
            > "${DOXYGEN_AWESOME_DIR}/${file}"
    done
    echo "${doxygen_awesome_version}" > "${DOXYGEN_AWESOME_VERSION_FILE}"
fi

# --- HTML header ---

# `-w html` writes the three stock templates; the footer and stylesheet are unused,
# the Doxyfile leaving both to doxygen's built-in ones.
"${doxygen_binary}" -w html \
    "${CACHE_DIR}/header.html" \
    "${CACHE_DIR}/footer.html" \
    "${CACHE_DIR}/stylesheet.css"

awk '
    FNR == NR { snippet = snippet $0 ORS; next }
    /<\/head>/ { printf "%s", snippet }
    { print }
' "${THEME_SCRIPTS}" "${CACHE_DIR}/header.html" > "${CACHE_DIR}/header.html.injected"
mv "${CACHE_DIR}/header.html.injected" "${CACHE_DIR}/header.html"

# --- render ---

rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"

# GitHub Pages runs Jekyll over the branch it serves unless told not to, and Jekyll drops any path starting with an underscore.
touch "${OUTPUT_DIR}/.nojekyll"

"${doxygen_binary}" "${DOXYFILE}"

echo "Done: ${OUTPUT_DIR}/"
