#!/bin/bash

set -eu

# =============================================================================================
# This file is part of https://github.com/GuillaumeDua/cpp-toolchain
# License: see https://github.com/GuillaumeDua/cpp-toolchain/blob/main/LICENSE
#
# Install Bazel from its apt repository (https://bazel.build/install/ubuntu).
#
# WARNING: experimentale support
#
# amd64 only: the repository publishes no arm64 debs, so on any other architecture this installs
# nothing and says so rather than failing. Bazelisk is the portable route there.
# =============================================================================================

this_script_name=$(basename "$0")

arg_silent=1

# How many times a network-facing step is attempted
max_attempts=3

# storage.googleapis.com publishes no throttling window; this is a plain transient-failure backoff.
retry_backoff_seconds=5

gpg_key_url='https://bazel.build/bazel-release.pub.gpg'
gpg_key_path='bazel-release.pub.gpg'
gpg_key_installed_path='/usr/share/keyrings/bazel-archive-keyring.gpg'
apt_source_path='/etc/apt/sources.list.d/bazel.list'
apt_source_url='https://storage.googleapis.com/bazel-apt'

# The suite the repository is indexed under. Unlike the other apt sources in this repository, it is
# not the host's codename, so nothing here reads lsb_release.
apt_suite='stable jdk1.8'

help(){
    echo "Usage: ${this_script_name}" >&2
    echo "
    Boolean values: y|yes|1|true or n|no|0|false (case insensitive)

        [ -s | --silent ]   : Run in silent mod.    Boolean -> default is [1]
        [ -h | --help ]     : Display usage/help

    Registers ${apt_source_url} and installs the 'bazel' package from it.
    No version is requested, so apt resolves whatever the repository currently serves.

    amd64 only. On any other architecture nothing is installed and the script exits 0, because the
    repository carries no deb for it - use Bazelisk there instead.

    For instance:
        sudo ./${this_script_name}
        " >&2
    exit 0
}

clean(){
    if [ -f "${gpg_key_path}" ]; then
        rm -f "${gpg_key_path}"
    fi
}
# Every exit path, including the ones that bypass the explicit call below.
trap clean EXIT

error_diagnosis(){
    {
        echo -e "[${this_script_name}]: diagnosis helper:"
        echo -e "\t- host architecture:  [$(dpkg --print-architecture 2>/dev/null || uname -m)]"
        echo -e "\t- signing key:        [$([ -f "${gpg_key_installed_path}" ] && echo "${gpg_key_installed_path}" || echo '<not installed>')]"
        echo -e "\t- apt source:         [$([ -f "${apt_source_path}" ] && echo "${apt_source_path}" || echo '<not registered>')]"
    } >&2
}

# The helpers shared with the other scripts. The standalone copy published for each release
# carries them inlined here instead - scripts/details/compose-standalone.py.
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/../details/shared.sh"

# --- options management ---

options_short=s:,h
options_long=silent:,help
getopt_result=$(getopt -a -n ${this_script_name} --options ${options_short} --longoptions ${options_long} -- "$@")

eval set -- "$getopt_result"

while :
do
  case "$1" in
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

# --- precondition: a supported architecture ---

# Ahead of the root check: there is nothing to install here, so asking for privileges first would
# refuse a call that was always going to be a no-op.
architecture=$(dpkg --print-architecture 2>/dev/null || echo unknown)
if [ "${architecture}" != 'amd64' ]; then
    echo "[${this_script_name}]: the Bazel apt repository is amd64-only, installing nothing on ${architecture} - use Bazelisk"
    exit 0
fi

# --- precondition: sudoer ---

if [ "$EUID" -ne 0 ]; then
    error "Requires root privileges"
fi

log "arguments - silent:            [${arg_silent}]"

# --- prerequisites ---

run_with_retries "${max_attempts}" "refreshing the apt index" \
    apt-get update -qqy -o Acquire::Retries=${max_attempts} \
|| error "refreshing the apt index failed"

run_with_retries "${max_attempts}" "installing the fetch prerequisites" \
    apt-get install -qqy --no-install-recommends -o Acquire::Retries=${max_attempts} \
        apt-transport-https curl gnupg \
|| error "installing [apt-transport-https curl gnupg] failed"

# --- register the Bazel apt repository ---

# The fetch is not piped into gpg: without pipefail, a failed download would surface as a malformed key.
# Installed unconditionally, never skipped on the file being present: gpg --dearmor creates its output
#   before writing it, so an interrupted run leaves a truncated key that a presence check reads as installed,
#   and every later apt-get update then fails with NO_PUBKEY until someone removes it by hand.
run_with_retries "${max_attempts}" "fetching the signing key [${gpg_key_url}]" \
    curl --fail --silent --show-error --location --retry ${max_attempts} --output "${gpg_key_path}" "${gpg_key_url}" \
|| error "fetching the signing key [${gpg_key_url}] failed"

run "installing the signing key" \
    gpg --dearmor --batch --yes -o "${gpg_key_installed_path}" "${gpg_key_path}" \
|| error "installing the signing key fetched from [${gpg_key_url}] failed"
clean

# arch= pins the source to the only architecture it serves, so an apt-get update on another one
# reports nothing rather than a missing index.
echo "deb [arch=amd64 signed-by=${gpg_key_installed_path}] ${apt_source_url} ${apt_suite}" > "${apt_source_path}" \
|| error "registering [${apt_source_path}] failed"

run_with_retries "${max_attempts}" "refreshing the apt index" \
    apt-get update -qqy -o Acquire::Retries=${max_attempts} \
|| error "refreshing the apt index failed"

# --- installation ---

run_with_retries "${max_attempts}" "installing [bazel]" \
    apt-get install -qqy --no-install-recommends -o Acquire::Retries=${max_attempts} bazel \
|| error "installation of bazel failed"

# --- summary ---

bazel_version=$(dpkg-query -W -f='${Version}' bazel)
log "Bazel version now installed: [${bazel_version}]"
echo -e "${bazel_version}" # result for the caller

exit 0;
