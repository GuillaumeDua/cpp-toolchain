#!/bin/bash

set -eu

# =============================================================================================
# This file is part of https://github.com/GuillaumeDua/cpp-toolchain
# License: see https://github.com/GuillaumeDua/cpp-toolchain/blob/main/LICENSE
#
# Install the build2 toolchain (https://build2.org) from its upstream installer.
#
# build2 is built from source by that installer, so a C++ compiler has to be here already.
# This script installs none: gcc.sh and llvm.sh own that, and guessing one would install a
# toolchain the caller did not ask for.
# =============================================================================================

this_script_name=$(basename "$0")

arg_versions=''
arg_cxx='clang++'
arg_silent=1

# How many times a network-facing step is attempted
max_attempts=3

# download.build2.org publishes no throttling window; this is a plain transient-failure backoff.
retry_backoff_seconds=5

base_url='https://download.build2.org'
work_dir=''

help(){
    echo "Usage: ${this_script_name} --versions=<version> [options]" 1>&2
    echo "
    Boolean values: y|yes|1|true or n|no|0|false (case insensitive)

        [ -v | --versions ] : Version to install.       String: (exact-version) -> required, Ex: '0.16.0'
        [ -c | --cxx ]      : Compiler to build with.   String -> default is [${arg_cxx}]
        [ -s | --silent ]   : Run in silent mod.        Boolean -> default is [1]
        [ -h | --help ]     : Display usage/help

    Fetches ${base_url}/<version>/build2-install-<version>.sh and runs it.
    There is no 'latest': build2 publishes no index this script could resolve one from, so the
    version is always named by the caller.

    The installer compiles build2 from source, so [${arg_cxx}] - or whatever --cxx names - has to be
    installed already. gcc.sh and llvm.sh next door install one.

    For instance:
        sudo ./${this_script_name} --versions=0.16.0
        sudo ./${this_script_name} --versions=0.16.0 --cxx=g++
        " 1>&2
    exit 0
}

clean(){
    if [ -n "${work_dir}" ] && [ -d "${work_dir}" ]; then
        rm -rf "${work_dir}"
    fi
}
# Every exit path, including the ones that bypass the explicit call below.
trap clean EXIT

error_diagnosis(){
    {
        echo -e "[${this_script_name}]: diagnosis helper:"
        echo -e "\t- version requested:  [${arg_versions:-<unset>}]"
        echo -e "\t- compiler:           [${arg_cxx}] $(command -v "${arg_cxx}" 2>/dev/null || echo '<not on PATH>')"
        echo -e "\t- download base:      [${base_url}/${arg_versions:-<unset>}]"
    } >> /dev/stderr
}

# The helpers shared with the other scripts. The standalone copy published for each release
# carries them inlined here instead - scripts/details/compose-standalone.py.
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/../details/shared.sh"

# --- options management ---

options_short=v:,c:,s:,h
options_long=versions:,cxx:,silent:,help
getopt_result=$(getopt -a -n ${this_script_name} --options ${options_short} --longoptions ${options_long} -- "$@")

eval set -- "$getopt_result"

while :
do
  case "$1" in
    -v | --versions )
        arg_versions="$2"
        shift 2
        ;;
    -c | --cxx )
        arg_cxx="$2"
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
        echo "${this_script_name}: Unexpected option: [$1]" >> /dev/stderr
        help
        ;;
  esac
done

arg_silent=$(to_boolean "${arg_silent}")

# --- preconditions ---

if [ -z "${arg_versions}" ]; then
    error "--versions is required - there is no 'latest' to fall back to, see --help"
fi

# Ahead of the root check: a missing compiler is the harder of the two to fix, so report it first
# rather than sending the caller back for sudo and refusing a second time.
command -v "${arg_cxx}" >/dev/null 2>&1 \
  || error "compiler [${arg_cxx}] not found in PATH - the installer builds build2 from source, so install one first (gcc.sh / llvm.sh) or name another with --cxx"

if [ "$EUID" -ne 0 ]; then
    error "Requires root privileges"
fi

log "arguments - versions:          [${arg_versions}]"
log "arguments - cxx:               [${arg_cxx}]"
log "arguments - silent:            [${arg_silent}]"

# --- fetch the installer ---

installer="build2-install-${arg_versions}.sh"
release_url="${base_url}/${arg_versions}"

work_dir=$(mktemp -d)
cd "${work_dir}"

curl_options=(--fail --silent --show-error --location --retry ${max_attempts} --remote-name)

run_with_retries "${max_attempts}" "fetching [${release_url}/${installer}]" \
    curl "${curl_options[@]}" "${release_url}/${installer}" \
|| error "fetching [${release_url}/${installer}] failed - is [${arg_versions}] a published build2 release?"

run_with_retries "${max_attempts}" "fetching [${release_url}/${installer}.sha256]" \
    curl "${curl_options[@]}" "${release_url}/${installer}.sha256" \
|| error "fetching [${release_url}/${installer}.sha256] failed"

# The installer is checked against build2's own per-release sidecar rather than a hash pinned here,
# so a version bump stays a one-line change. sha256sum rather than shasum: both read this format,
# and only the first is in coreutils, which a host running the published copy is certain to have.
run "verifying [${installer}]" \
    sha256sum --check --strict "${installer}.sha256" \
|| error "[${installer}] does not match its published sha256 - refusing to run it"

# --- installation ---

# --sudo false: this script already requires root, and the installer would otherwise look for a sudo
#   that a minimal image has no reason to carry.
run "running [${installer}]" \
    sh "${installer}" --yes --cxx "${arg_cxx}" --sudo false --jobs "$(nproc)" \
|| error "running [${installer}] failed"

# --- summary ---

if command -v bpkg >/dev/null 2>&1; then
    log "build2 [${arg_versions}] installed, bpkg is on PATH"
else
    warning "the installer reported success but [bpkg] is not on PATH - check where it installed to"
fi

echo -e "${arg_versions}" # result for the caller

exit 0;
