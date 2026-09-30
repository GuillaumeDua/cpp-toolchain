#!/bin/bash

set -eu

# =============================================================================================
# This file is part of https://github.com/GuillaumeDua/cpp-toolchain
# License: see https://github.com/GuillaumeDua/cpp-toolchain/blob/main/LICENSE
#
# Install the build2 toolchain (https://build2.org): b, bpkg, bdep and bx.
#
# Two routes, in this order:
#   1. the binary package upstream publishes per distribution, release and architecture.
#   2. the source installer, which compiles build2 and therefore needs a C++ compiler already here.
#
# The source build is the fallback rather than the default because it is minutes of CPU for an
# artifact upstream already produced. It is not dead code: the binary packages cover x86_64 alone,
# and only some releases carry them - 0.16.0 has none at all.
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

# Set by resolve_package_url, read by error_diagnosis whichever route runs.
package_url=''
package_status=''

help(){
    echo "Usage: ${this_script_name} --versions=<version> [options]" 1>&2
    echo "
    Boolean values: y|yes|1|true or n|no|0|false (case insensitive)

        [ -v | --versions ] : Version to install.       String: (exact-version) -> required, Ex: '0.18.1'
        [ -c | --cxx ]      : Compiler to build with.   String -> default is [${arg_cxx}]
        [ -s | --silent ]   : Run in silent mod.        Boolean -> default is [1]
        [ -h | --help ]     : Display usage/help

    Installs the binary package upstream publishes for this distribution, release and architecture.
    Where there is none - another architecture, an unsupported release, a version that predates them -
    it falls back to compiling build2 from source with --cxx, which has to be installed already.
    gcc.sh and llvm.sh next door install one.

    There is no 'latest': build2 publishes no index this script could resolve one from, so the
    version is always named by the caller.

    For instance:
        sudo ./${this_script_name} --versions=0.18.1
        sudo ./${this_script_name} --versions=0.16.0 --cxx=g++   # no package for 0.16.0: source build
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
        echo -e "\t- binary package:     [${package_url:-<unresolved>}] -> [${package_status:-<not probed>}]"
        echo -e "\t- compiler:           [${arg_cxx}] $(command -v "${arg_cxx}" 2>/dev/null || echo '<not on PATH>')"
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

if [ "$EUID" -ne 0 ]; then
    error "Requires root privileges"
fi

log "arguments - versions:          [${arg_versions}]"
log "arguments - cxx:               [${arg_cxx}]"
log "arguments - silent:            [${arg_silent}]"

# --- which binary package, if any, answers for this host ---

# The layout is <id>/<id><version_id>/<machine>/, and the file name carries the dpkg architecture
# rather than the machine - ubuntu24.04/x86_64/build2-toolchain_0.18.1-0~ubuntu24.04_amd64.deb.
# Both spellings are needed, so both are read.
resolve_package_url(){
    local id version_id machine architecture

    id=$( . /etc/os-release 2>/dev/null && echo "${ID:-}" ) || id=''
    version_id=$( . /etc/os-release 2>/dev/null && echo "${VERSION_ID:-}" ) || version_id=''
    machine=$(uname -m 2>/dev/null) || machine=''
    architecture=$(dpkg --print-architecture 2>/dev/null) || architecture=''

    # Only the two apt distributions: the installation step below is apt-get, so a package for a
    # distribution this script cannot install on is not an answer.
    case "${id}" in
        ubuntu | debian ) ;;
        * ) return 1 ;;
    esac

    [ -n "${version_id}" ] && [ -n "${machine}" ] && [ -n "${architecture}" ] || return 1

    local release="${id}${version_id}"
    package_url="${base_url}/${arg_versions}/bindist/${id}/${release}/${machine}/build2-toolchain_${arg_versions}-0~${release}_${architecture}.deb"
    return 0
}

install_from_package(){
    local package_name
    package_name=$(basename "${package_url}")

    run_with_retries "${max_attempts}" "fetching [${package_name}]" \
        curl --fail --silent --show-error --location --retry ${max_attempts} --remote-name "${package_url}" \
    || error "fetching [${package_url}] failed"

    # One sidecar per directory, listing every package in it, so it is fetched by directory name.
    run_with_retries "${max_attempts}" "fetching [packages.sha256]" \
        curl --fail --silent --show-error --location --retry ${max_attempts} --remote-name "$(dirname "${package_url}")/packages.sha256" \
    || error "fetching the checksums beside [${package_name}] failed"

    # --ignore-missing: the sidecar covers every package in that directory, and only one was fetched.
    run "verifying [${package_name}]" \
        sha256sum --check --strict --ignore-missing packages.sha256 \
    || error "[${package_name}] does not match its published sha256 - refusing to install it"

    # apt-get rather than dpkg -i, so a dependency the package gains later resolves instead of
    # leaving it half-configured. The leading ./ is what makes apt read it as a file.
    run "installing [${package_name}]" \
        apt-get install -qqy --no-install-recommends -o Acquire::Retries=${max_attempts} "./${package_name}" \
    || error "installing [${package_name}] failed"
}

install_from_source(){
    local installer="build2-install-${arg_versions}.sh"
    local release_url="${base_url}/${arg_versions}"

    command -v "${arg_cxx}" >/dev/null 2>&1 \
      || error "no binary package for this host, and the source build needs a compiler: [${arg_cxx}] is not in PATH - install one (gcc.sh / llvm.sh) or name another with --cxx"

    run_with_retries "${max_attempts}" "fetching [${installer}]" \
        curl --fail --silent --show-error --location --retry ${max_attempts} --remote-name "${release_url}/${installer}" \
    || error "fetching [${release_url}/${installer}] failed - is [${arg_versions}] a published build2 release?"

    run_with_retries "${max_attempts}" "fetching [${installer}.sha256]" \
        curl --fail --silent --show-error --location --retry ${max_attempts} --remote-name "${release_url}/${installer}.sha256" \
    || error "fetching [${release_url}/${installer}.sha256] failed"

    # Checked against build2's own per-release sidecar, so no hash is pinned here and a version bump
    # stays a one-line change. sha256sum rather than shasum: both read this format, and only the
    # first is in coreutils, which a host running the published copy is certain to have.
    run "verifying [${installer}]" \
        sha256sum --check --strict "${installer}.sha256" \
    || error "[${installer}] does not match its published sha256 - refusing to run it"

    # --sudo false: this script already requires root, and the installer would otherwise look for a
    #   sudo that a minimal image has no reason to carry.
    run "running [${installer}]" \
        sh "${installer}" --yes --cxx "${arg_cxx}" --sudo false --jobs "$(nproc)" \
    || error "running [${installer}] failed"
}

# --- installation ---

work_dir=$(mktemp -d)
cd "${work_dir}"

if resolve_package_url; then
    # A HEAD rather than letting the download fail: 404 means there is no package for this host and
    # the source build is the answer, while a timeout or a 5xx means the question went unanswered -
    # falling back there would spend minutes compiling over what is probably a transient failure.
    package_status=$(curl --silent --location --head --max-time 30 \
                          --output /dev/null --write-out '%{http_code}' "${package_url}") || package_status='000'
else
    package_status='n/a'
    log "no binary package is published for this distribution"
fi

case "${package_status}" in
    200 )
        log "installing the binary package [${package_url}]"
        install_from_package
        ;;
    404 | 'n/a' )
        log "no binary package for this host, building [${arg_versions}] from source with [${arg_cxx}]"
        install_from_source
        ;;
    * )
        error "cannot tell whether a binary package exists: [${package_url}] answered [${package_status}]"
        ;;
esac

# --- summary ---

installed=()
for command_name in b bpkg bdep bx; do
    command -v "${command_name}" >/dev/null 2>&1 && installed+=("${command_name}")
done

[ "${#installed[@]}" -gt 0 ] \
  || error "the installation reported success but none of [b bpkg bdep bx] is on PATH"

log "build2 [${arg_versions}] installed: ${installed[*]}"

echo -e "${arg_versions}" # result for the caller

exit 0;
