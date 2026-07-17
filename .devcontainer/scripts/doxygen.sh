#!/usr/bin/env bash
# Install a pre-built Doxygen release (Linux x86_64 CLI binary) from GitHub.
#
#   Ubuntu's `doxygen` apt package lags upstream badly, so favor the official pre-built binary instead.
#   Only the `doxygen` binary is pulled out of the release tarball;
#   the `dot` renderer still comes from the graphviz apt package.
#
#   Argument: the GitHub release tag, e.g. `Release_1_17_0` (bumped by Renovate, see renovate.json).
#   Doxygen tags use underscores (`Release_1_17_0`) while the download asset uses dots
#   (`doxygen-1.17.0.linux.bin.tar.gz`), so both forms are derived below from the single tag.
set -euo pipefail

tag="${1:?usage: doxygen.sh <release-tag>, e.g. Release_1_17_0}"
version="${tag#Release_}"   # 1_17_0
version="${version//_/.}"   # 1.17.0
url="https://github.com/doxygen/doxygen/releases/download/${tag}/doxygen-${version}.linux.bin.tar.gz"

echo "[doxygen] installing ${version} from ${url}"
curl -fsSL "${url}" \
    | tar -xz -C /usr/local/bin --strip-components=2 "doxygen-${version}/bin/doxygen"
doxygen --version
