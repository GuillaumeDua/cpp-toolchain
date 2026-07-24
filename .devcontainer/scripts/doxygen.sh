#!/usr/bin/env bash
# Install Doxygen.
#
#   amd64:
#       install the official pre-built Linux binary from GitHub.
#       Ubuntu's `doxygen` apt package lags upstream badly, so the pre-built binary is favored.
#       Only the `doxygen` binary is pulled out of the release tarball;
#       the `dot` renderer still comes from the graphviz apt package.
#
#   Other architectures:
#       Doxygen publishes no aarch64 pre-built binary,
#       so fall back to the distro apt package (older, but the only portable option other than dedicated source build).
#
#   Argument:
#       the GitHub release tag, e.g. `Release_1_17_0` (bumped by Renovate, see renovate.json).
#       Doxygen tags use underscores (`Release_1_17_0`) while the download asset uses dots (`doxygen-1.17.0.linux.bin.tar.gz`), 
#       so both forms are derived below from the single tag.

set -euo pipefail

tag="${1:?usage: doxygen.sh <release-tag>, e.g. Release_1_17_0}"

arch="$(dpkg --print-architecture)"
if [[ "${arch}" != "amd64" ]]; then
    # No upstream pre-built binary for this architecture - fall back to the distro package.
    echo "[doxygen] no upstream pre-built binary for ${arch}, installing the apt package"
    apt-get update -qqy
    apt-get install -qqy --no-install-recommends doxygen
    doxygen --version
    exit 0
fi

version="${tag#Release_}"   # 1_17_0
version="${version//_/.}"   # 1.17.0
url="https://github.com/doxygen/doxygen/releases/download/${tag}/doxygen-${version}.linux.bin.tar.gz"

echo "[doxygen] installing ${version} from ${url}"
curl -fsSL "${url}" \
    | tar -xz -C /usr/local/bin --strip-components=2 "doxygen-${version}/bin/doxygen"
doxygen --version
