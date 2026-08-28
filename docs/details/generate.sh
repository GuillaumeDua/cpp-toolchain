#!/usr/bin/env bash

# Render the repository's markdown as the documentation site, into docs/output.
# .github/workflows/documentation.yml runs this and publishes the result to GitHub Pages.
#
# Prerequisites: bash, curl, tar, awk, and python3 for the Doxyfile's INPUT_FILTER.
# Nothing beyond that - no graphviz, and no Node.js, because mermaid diagrams render client-side.
#
# Doxygen and the doxygen-awesome-css theme are fetched at the versions pinned below rather than committed,
# and cached, so a re-run with nothing new to fetch goes straight to rendering.
# Doxygen itself comes from scripts/install/doxygen.sh, the installer the images use, under a --prefix.
#
# The HTML header is generated from the running doxygen's own template rather than committed as a file.
# A committed header is pinned to the doxygen version it was written for and silently loses whatever
# later versions add to it - which is how a $mermaidjs-less header would leave every diagram blank.

set -euo pipefail

readonly INVOCATION_DIRECTORY="${PWD}"

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

readonly DOXYFILE="docs/details/Doxyfile"
readonly THEME_SCRIPTS="docs/details/theme-scripts.html"
readonly CACHE_DIR="docs/details/.cache"
readonly OUTPUT_DIR="docs/output"

# The site renders with the doxygen the `documentation` image ships, so there is one pin rather than two:
# Renovate owns it and scripts/details/check-dependencies-pins.py guards it.
readonly DOXYGEN_PIN_SOURCE="Dockerfile"

# The theme is not installed in any image, so its pin lives here.
# renovate: datasource=github-releases depName=jothepro/doxygen-awesome-css
readonly DOXYGEN_AWESOME_PIN=v2.4.2

# ```mermaid fences are rendered from doxygen 1.17.0 on (doxygen PR #12069); before that they come out as code blocks.
readonly DOXYGEN_MINIMUM_VERSION="1.17.0"

# Matches the retry count scripts/install/doxygen.sh applies to its own download.
readonly MAX_ATTEMPTS=3

# Doxygen cannot pair the backtick that opens the linker error quoted in scripts/checks/README.md:
# its pre-scanner does not recognize a fence nested in a blockquote, so it counts backticks across the
# whole file and falls out of phase. The page renders correctly.
# Subtracted here so that a reported diagnostic always means something worth reading.
readonly KNOWN_BENIGN_DIAGNOSTIC='scripts/checks/README\.md:[0-9]+: warning: Reached end of file while still searching closing'

# --- arguments ---

doxygen_version=
doxygen_awesome_version=
diagnostics_file=
print_versions=false

usage() {
    cat <<'USAGE'
Usage: docs/details/generate.sh [options]

  --doxygen-version <version>         Override the Dockerfile's ARG DOXYGEN_RELEASE pin.
  --doxygen-awesome-version <version> Override the theme pin.
  --diagnostics <file>                Also write doxygen's diagnostics there, empty when there are none.
  --print-versions                    Print the resolved versions as name=value and exit.

Both versions accept an optional leading `v`.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --doxygen-version)         doxygen_version="$2";        shift 2 ;;
        --doxygen-awesome-version) doxygen_awesome_version="$2"; shift 2 ;;
        --diagnostics)             diagnostics_file="$2";        shift 2 ;;
        --print-versions)          print_versions=true;          shift   ;;
        -h|--help)                 usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# The caller wrote this path against their own directory, not the repository root this script moved to.
if [[ -n "${diagnostics_file}" && "${diagnostics_file}" != /* ]]; then
    diagnostics_file="${INVOCATION_DIRECTORY}/${diagnostics_file}"
fi

# --- helpers ---

http_download() {
    local url="$1" destination="$2"

    curl -fsSL --retry "${MAX_ATTEMPTS}" --retry-delay 2 --retry-connrefused -o "${destination}" "${url}"
}

# The lowest of the two arguments, per `sort -V`.
lowest_version() {
    printf '%s\n%s\n' "$1" "$2" | sort -V | head -1
}

# Release_1_17_0 -> 1.17.0
release_tag_to_version() {
    local version="${1#Release_}"
    echo "${version//_/.}"
}

# --- versions ---

if [[ -z "${doxygen_version}" ]]; then
    pinned_release=$(grep -oP '^ARG DOXYGEN_RELEASE=\K\S+' "${DOXYGEN_PIN_SOURCE}") \
        || { echo "no 'ARG DOXYGEN_RELEASE=' pin found in ${DOXYGEN_PIN_SOURCE}" >&2; exit 1; }
    doxygen_version=$(release_tag_to_version "${pinned_release}")
fi
doxygen_version="${doxygen_version#v}"

if [[ -z "${doxygen_awesome_version}" ]]; then
    doxygen_awesome_version="${DOXYGEN_AWESOME_PIN}"
fi
doxygen_awesome_version="${doxygen_awesome_version#v}"

if [[ "$(lowest_version "${doxygen_version}" "${DOXYGEN_MINIMUM_VERSION}")" != "${DOXYGEN_MINIMUM_VERSION}" ]]; then
    echo "doxygen ${doxygen_version} is below the required ${DOXYGEN_MINIMUM_VERSION}: mermaid diagrams would not render." >&2
    exit 1
fi

if [[ "${print_versions}" == true ]]; then
    echo "doxygen=${doxygen_version}"
    echo "theme=${doxygen_awesome_version}"
    exit 0
fi

echo "doxygen ${doxygen_version} / doxygen-awesome-css ${doxygen_awesome_version}"

mkdir -p "${CACHE_DIR}"

# --- doxygen ---

# Installed by scripts/install/doxygen.sh, the installer the images use, so the release URL and the
# layout inside its tarball are stated once.
# The prefix is temporary and moved into place afterwards: a transfer cut off part way would otherwise
# leave an executable, truncated binary that the -x test below trusts on every later run.
fetch_doxygen() {
    local unpack_dir
    unpack_dir=$(mktemp -d)
    trap 'rm -rf "${unpack_dir}"' RETURN

    bash scripts/install/doxygen.sh \
        --prefix="${unpack_dir}/doxygen" \
        "Release_${doxygen_version//./_}"
    mv "${unpack_dir}/doxygen" "${CACHE_DIR}/doxygen-${doxygen_version}"
}

# An installed doxygen is only reused when it is the exact version asked for,
# so the site never renders with something other than what this run reports.
doxygen_binary="doxygen"
if [[ "$(command -v doxygen &>/dev/null && doxygen --version | cut -d' ' -f1)" != "${doxygen_version}" ]]; then
    doxygen_binary="${CACHE_DIR}/doxygen-${doxygen_version}/bin/doxygen"

    if [[ ! -x "${doxygen_binary}" ]]; then
        echo "Downloading doxygen ${doxygen_version}..."
        fetch_doxygen
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

# The version marker is written last, so a download interrupted part way is retried rather than trusted.
if [[ "$(cat "${DOXYGEN_AWESOME_VERSION_FILE}" 2>/dev/null || true)" != "${doxygen_awesome_version}" ]]; then
    echo "Downloading doxygen-awesome-css ${doxygen_awesome_version}..."
    rm -rf "${DOXYGEN_AWESOME_DIR}"
    mkdir -p "${DOXYGEN_AWESOME_DIR}"
    for file in "${DOXYGEN_AWESOME_FILES[@]}"; do
        http_download \
            "https://raw.githubusercontent.com/jothepro/doxygen-awesome-css/v${doxygen_awesome_version}/${file}" \
            "${DOXYGEN_AWESOME_DIR}/${file}"
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

raw_diagnostics=$(mktemp)
trap 'rm -f "${raw_diagnostics}"' EXIT

"${doxygen_binary}" "${DOXYFILE}" 2> "${raw_diagnostics}"

# Doxygen writes its warnings to stderr, and so does the shell it spawns for INPUT_FILTER,
# so a filter that cannot run is visible here even though doxygen still exits 0.
# Doxygen names the file by absolute path and STRIP_FROM_PATH does not reach its warnings,
# so the repository root is cut here to leave the same relative paths the documentation uses.
diagnostics=$(grep -Ev "${KNOWN_BENIGN_DIAGNOSTIC}" "${raw_diagnostics}" | sed "s|${PWD}/||g" || true)

# A trailing newline only when there is something to report: the workflow tests the file's size,
# so a clean run has to leave zero bytes rather than a lone newline.
if [[ -n "${diagnostics_file}" ]]; then
    if [[ -n "${diagnostics}" ]]; then
        printf '%s\n' "${diagnostics}" > "${diagnostics_file}"
    else
        : > "${diagnostics_file}"
    fi
fi
if [[ -n "${diagnostics}" ]]; then
    echo "${diagnostics}" >&2
fi

# Doxygen exits 0 when its INPUT_FILTER cannot run, having read every input and written nothing from any of them.
# Publishing that empties the site, so it is a failure here rather than a green run.
page_count=$(find "${OUTPUT_DIR}" -maxdepth 1 -name 'md_*.html' | wc -l)
if [[ ! -s "${OUTPUT_DIR}/index.html" || "${page_count}" -eq 0 ]]; then
    echo "the render produced ${page_count} pages: doxygen read the input and wrote nothing from it, which is what a failed INPUT_FILTER looks like." >&2
    exit 1
fi

echo "Done: ${OUTPUT_DIR}/ (${page_count} pages beside the main page)"
