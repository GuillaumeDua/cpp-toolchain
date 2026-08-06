#!/bin/bash
set -uo pipefail

# See docs/IMAGES_VALIDATION.md

this_script_name=$(basename "$0")

origin_toolchain_ppa='ppa.launchpadcontent.net/ubuntu-toolchain-r'
origin_llvm='apt.llvm.org'
origin_kitware='apt.kitware.com'

recorded_versions_file="${RECORDED_VERSIONS_FILE:-/etc/bash.bashrc}"

failures=0

die()  { echo "[${this_script_name}] error: $*" >&2; exit 1; }
fail() { echo "[${this_script_name}] FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "[${this_script_name}] ok:   $*"; }

is_installed(){
    dpkg-query --show --showformat='${Status}\n' "$1" 2>/dev/null \
      | grep -q '^install ok installed$'
}

# The repository that provided the installed version, as apt reports it:
# the line right below the `***` marker names it.
installed_origin(){
    apt-cache policy "$1" 2>/dev/null | grep -A1 -- '^ \*\*\*' | tail -n 1
}

check_origin(){
    local package="$1"
    local expected="$2"

    if ! is_installed "${package}"; then
        fail "[${package}] is not installed"
        return
    fi

    local origin
    origin=$(installed_origin "${package}")
    if [ -z "${origin}" ]; then
        fail "[${package}] has no known origin - apt lists are missing, run apt-get update first"
        return
    fi

    if [[ "${origin}" == *"${expected}"* ]]; then
        pass "[${package}] provided by ${expected}"
    else
        fail "[${package}] expected from [${expected}], apt reports:${origin}"
    fi
}

# The install scripts append the versions they resolved, so `>=15` is recorded as what it became.
# The last assignment wins, since a stage may re-run an installer.
recorded_versions(){
    grep -oP "^$1='\K[^']*" "${recorded_versions_file}" 2>/dev/null | tail -n 1
}

check_recorded_versions(){
    local name="$1"
    local recorded="$2"
    local requested="$3"

    if [ -z "${recorded}" ]; then
        fail "[${name}] nothing recorded in ${recorded_versions_file} - the installer did not run with --alias=yes"
        return
    fi
    pass "[${name}] resolved to [${recorded}]"

    # A build argument naming a bare major must appear in what was actually installed.
    # Selectors such as '>=15' or 'latest-stable' resolve at build time and cannot be checked here.
    if [[ "${requested}" =~ ^[0-9]+$ ]] && ! grep -qw -- "${requested}" <<< "${recorded}"; then
        fail "[${name}] build argument requested [${requested}] but it is absent from [${recorded}]"
    fi
}

check_runtime_libraries(){
    check_origin 'libstdc++6' "${origin_toolchain_ppa}"
    check_origin 'libgcc-s1'  "${origin_toolchain_ppa}"
}

check_build_toolchains(){
    local recorded_gcc
    local recorded_llvm
    recorded_gcc=$(recorded_versions 'gcc_versions')
    recorded_llvm=$(recorded_versions 'llvm_versions')

    check_recorded_versions 'gcc_versions'  "${recorded_gcc}"  "${GCC_VERSIONS:-}"
    check_recorded_versions 'llvm_versions' "${recorded_llvm}" "${LLVM_VERSIONS:-}"

    local gcc_versions
    local llvm_versions
    read -r -a gcc_versions  <<< "${recorded_gcc}"
    read -r -a llvm_versions <<< "${recorded_llvm}"

    local version
    for version in "${gcc_versions[@]}"; do
        check_origin "gcc-${version}" "${origin_toolchain_ppa}"
        check_origin "g++-${version}" "${origin_toolchain_ppa}"
    done
    for version in "${llvm_versions[@]}"; do
        check_origin "clang-${version}"          "${origin_llvm}"
        check_origin "libc++-${version}-dev"     "${origin_llvm}"
        check_origin "libc++abi-${version}-dev"  "${origin_llvm}"
    done

    check_origin 'cmake' "${origin_kitware}"
}

stage="${1:-}"
case "${stage}" in
    runtime )
        check_runtime_libraries
        ;;
    build )
        check_runtime_libraries
        check_build_toolchains
        ;;
    * )
        die "usage: ${this_script_name} <build|runtime>"
        ;;
esac

[ "${failures}" -eq 0 ] \
  || die "${failures} origin check(s) failed on stage [${stage}]"

echo "[${this_script_name}] stage [${stage}]: every package comes from the repository that owns it"
exit 0
