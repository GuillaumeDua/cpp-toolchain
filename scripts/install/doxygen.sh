#!/usr/bin/env bash

set -euo pipefail

# =============================================================================================
# This file is part of https://github.com/GuillaumeDua/cpp-toolchain
# License: see https://github.com/GuillaumeDua/cpp-toolchain/blob/main/LICENSE
#
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
# =============================================================================================

this_script_name=$(basename "$0")

# How many times a network-facing step is attempted
max_attempts=3

error(){
    echo -e "[${this_script_name}]: $@" >> /dev/stderr
    echo -e "[${this_script_name}]: diagnosis helper:" >> /dev/stderr
    echo -e "\t- release tag:        [${tag:-<unset>}]" >> /dev/stderr
    echo -e "\t- host architecture:  [${arch:-<unresolved>}]" >> /dev/stderr
    exit 1
}

tag="${1:?usage: doxygen.sh <release-tag>, e.g. Release_1_17_0}"

arch="$(dpkg --print-architecture)"
if [[ "${arch}" != "amd64" ]]; then
    # No upstream pre-built binary for this architecture - fall back to the distro package.
    echo "[${this_script_name}]: no upstream pre-built binary for ${arch}, installing the apt package"
    apt-get update -qqy -o Acquire::Retries=${max_attempts} \
    || error "refreshing the apt index failed"
    apt-get install -qqy --no-install-recommends -o Acquire::Retries=${max_attempts} doxygen \
    || error "installing the [doxygen] apt package failed"
    doxygen --version
    exit 0
fi

version="${tag#Release_}"   # 1_17_0
version="${version//_/.}"   # 1.17.0
url="https://github.com/doxygen/doxygen/releases/download/${tag}/doxygen-${version}.linux.bin.tar.gz"

echo "[${this_script_name}]: installing ${version} from ${url}"
archive=$(mktemp)
trap 'rm -f "${archive}"' EXIT

# curl --retry handles transient failures; a 404 is not retried.
curl -fsSL --retry ${max_attempts} --retry-delay 2 --retry-connrefused -o "${archive}" "${url}" \
|| error "fetching [${url}] failed - is [${tag}] a published doxygen release?"

tar -xzf "${archive}" -C /usr/local/bin --strip-components=2 "doxygen-${version}/bin/doxygen" \
|| error "extracting [doxygen-${version}/bin/doxygen] from [${url}] failed"

doxygen --version
