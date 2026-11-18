#!/bin/bash

set -eu

# =============================================================================================
# This file is part of https://github.com/GuillaumeDua/cpp-toolchain
# License: see https://github.com/GuillaumeDua/cpp-toolchain/blob/main/LICENSE
#
# Install Ninja (https://ninja-build.org) from the single pre-built binary upstream publishes
# per platform.
#
# The alternative is the distribution's `ninja-build` package, which lags: Ubuntu 24.04 carries
# 1.11.1, released in August 2022.
# Upstream builds cover x86_64 and aarch64, so any other architecture takes that package instead.
# =============================================================================================

this_script_name=$(basename "$0")

arg_versions='latest'
arg_silent=1

# How many times a network-facing step is attempted
max_attempts=3

# What run_with_retries waits between attempts; the apt fallback's index refresh is its one caller.
retry_backoff_seconds=5

install_dir='/usr/local/bin'

work_dir=''

# The upstream asset for this host, left empty where there is none - which selects the apt fallback.
asset=''
asset_url=''

help(){
    echo "Usage: ${this_script_name} [options]" >&2
    echo "
    Boolean values: y|yes|1|true or n|no|0|false (case insensitive)

        [ -v | --versions ] : Version to install.   String: latest|(exact-version) -> default is [latest]
            - [latest]      : the newest published release, resolved through GitHub's own redirect
            - [x.y.z]       : an exact release, with or without the tag's 'v' prefix    Ex: '1.13.2'
        [ -s | --silent ]   : Run in silent mod.    Boolean -> default is [1]
        [ -h | --help ]     : Display usage/help

    Installs the upstream pre-built binary as ${install_dir}/ninja.
    On an architecture upstream publishes no binary for, the distribution's ninja-build package is
    installed instead - older, but the only portable option short of a source build.

    For instance:
        sudo ./${this_script_name}
        sudo ./${this_script_name} --versions=1.13.2
        " >&2
    exit 0
}

clean(){
    if [ -n "${work_dir}" ] && [ -d "${work_dir}" ]; then
        rm -rf "${work_dir}"
    fi
}
trap clean EXIT

error_diagnosis(){
    {
        echo -e "[${this_script_name}]: diagnosis helper:"
        echo -e "\t- version requested:  [${arg_versions}]"
        echo -e "\t- host architecture:  [${architecture:-<unresolved>}]"
        echo -e "\t- release asset:      [${asset_url:-<unresolved>}]"
    } >&2
}

# The helpers shared with the other scripts. The standalone copy published for each release
# carries them inlined here instead - scripts/internal/host/compose_standalone.py.
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/../lib/shared.sh"

# --- options management ---

options_short=v:,s:,h
options_long=versions:,silent:,help
getopt_result=$(getopt -a -n ${this_script_name} --options ${options_short} --longoptions ${options_long} -- "$@")

eval set -- "$getopt_result"

while :
do
  case "$1" in
    -v | --versions )
        arg_versions="$2"
        shift 2
        ;;
    -s | --silent )
        arg_silent="$2"
        shift 2
        ;;
    -h | --help)
        help
        exit 0
        shift
        ;;
    --)
        shift;
        break
        ;;
    *)
        echo "${this_script_name}: Unexpected option: [$1]" >&2
        help
        ;;
  esac
done

arg_silent=$(to_boolean "${arg_silent}")

# --- precondition: sudoer ---

if [ "$EUID" -ne 0 ]; then
    error "Requires root privileges"
fi

log "arguments - versions:          [${arg_versions}]"
log "arguments - silent:            [${arg_silent}]"

# --- which route answers for this host ---

architecture=$(host_architecture)

case "${architecture}" in
    amd64 ) asset='ninja-linux.zip' ;;
    arm64 ) asset='ninja-linux-aarch64.zip' ;;
esac

# --- installation ---

if [ -z "${asset}" ]; then
    # Always on stderr: the version asked for is not what apt installs.
    warning "no upstream pre-built binary for [${architecture}], installing the ninja-build apt package"

    run_with_retries "${max_attempts}" "refreshing the apt index" apt-get update -qqy -o Acquire::Retries=${max_attempts} \
    || error "refreshing the apt index failed"

    apt-get install -qqy --no-install-recommends -o Acquire::Retries=${max_attempts} ninja-build \
    || error "installation of the ninja-build apt package failed"

    # Where the package writes it, which is what the summary below reads.
    install_dir='/usr/bin'
else
    command -v unzip >/dev/null 2>&1 \
    || error "unpacking [${asset}] needs the unzip package, which this host does not have"

    # `latest` resolves through the redirect github.com serves on /releases/latest/download/ rather
    # than through its API, which answers an unauthenticated caller 60 times an hour.
    release_path=$([ "${arg_versions}" = 'latest' ] && echo 'latest/download' || echo "download/v${arg_versions#v}")
    asset_url="https://github.com/ninja-build/ninja/releases/${release_path}/${asset}"

    work_dir=$(mktemp -d)

    # curl --retry handles transient failures; a 404 is not retried, so an unpublished version
    # fails at once rather than after three attempts at it.
    curl --fail --silent --show-error --location --retry ${max_attempts} --retry-delay 2 --retry-connrefused \
         --output "${work_dir}/${asset}" "${asset_url}" \
    || error "fetching [${asset_url}] failed - is [${arg_versions}] a published ninja release?"

    unzip -q -o "${work_dir}/${asset}" ninja -d "${work_dir}" \
    || error "extracting [ninja] from [${asset}] failed"

    install -m 0755 "${work_dir}/ninja" "${install_dir}/ninja" \
    || error "installing [${install_dir}/ninja] failed"
fi

# --- summary ---

# Qualified, so this reports what was just installed rather than whatever PATH resolves to.
ninja_version=$("${install_dir}/ninja" --version)
log "Ninja version now installed: [${ninja_version}]"
echo -e "${ninja_version}" # result for the caller

# A `ninja` earlier on PATH, or a PATH without ${install_dir}, answers for the command instead of
# what was just installed, while the install itself reports success.
resolved=$(command -v ninja 2>/dev/null || true)
if [ "${resolved}" != "${install_dir}/ninja" ]; then
    warning "[ninja] resolves to [${resolved:-<nothing on PATH>}] rather than [${install_dir}/ninja]"
fi

exit 0;
