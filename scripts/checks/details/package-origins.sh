#!/bin/bash
set -uo pipefail

# See docs/IMAGES_VALIDATION.md

this_script_name=$(basename "$0")
this_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# The installers own how their packages are named, so they answer what is installed.
install_scripts_dir="${this_script_dir}/../../install"

origin_toolchain_ppa='ppa.launchpadcontent.net/ubuntu-toolchain-r'
origin_llvm='apt.llvm.org'
origin_kitware='apt.kitware.com'

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

# Only the majors the build argument names are part of the promise.
# The distribution's own GCC arrives as a build-essential dependency, from the Ubuntu archive,
# and is a legitimate inhabitant of the image rather than a regression.
#
# A selector such as '>=15' or 'latest-stable' resolves against apt at build time,
# so which majors it produced cannot be recomputed here.
# Those builds fall back to requiring that at least one installed compiler comes from the right place.
# `patterns` are package names in which %s stands for a major, so a toolchain can name more than
# its compiler - the libc++ runtimes belong to the clang major that llvm.sh was asked to install,
# and to no other.
check_toolchain_origin(){
    local label="$1"
    local requested="$2"
    local expected="$3"
    local installed="$4"
    local patterns="$5"

    if [ -z "${installed}" ]; then
        fail "[${label}] no compiler is installed"
        return
    fi
    pass "[${label}] compilers installed for major(s) [${installed}]"

    local major
    local pattern

    if [[ "${requested}" =~ ^[0-9]+( [0-9]+)*$ ]]; then
        for major in ${requested}; do
            if ! grep -qw -- "${major}" <<< "${installed}"; then
                fail "[${label}] build argument requested [${major}] but no compiler is installed for it"
                continue
            fi
            for pattern in ${patterns}; do
                check_origin "${pattern//%s/${major}}" "${expected}"
            done
        done
        return
    fi

    # Probe the compiler package alone here: what a selector installed alongside it is not knowable.
    local compiler_pattern="${patterns%% *}"
    for major in ${installed}; do
        local package="${compiler_pattern//%s/${major}}"
        if is_installed "${package}" && [[ "$(installed_origin "${package}")" == *"${expected}"* ]]; then
            pass "[${label}] selector [${requested}] resolved to at least ${package}, from ${expected}"
            return
        fi
    done
    fail "[${label}] selector [${requested}] resolved to [${installed}], none of them from ${expected}"
}

check_runtime_libraries(){
    check_origin 'libstdc++6' "${origin_toolchain_ppa}"
    check_origin 'libgcc-s1'  "${origin_toolchain_ppa}"
}

check_build_toolchains(){
    [ -d "${install_scripts_dir}" ] \
      || die "cannot find scripts/install two levels above scripts/checks/details"

    local gcc_majors
    local clang_majors
    gcc_majors=$(bash "${install_scripts_dir}/gcc.sh"  --list-installed | tr '\n' ' ' | sed 's/ $//')
    clang_majors=$(bash "${install_scripts_dir}/llvm.sh" --list-installed | tr '\n' ' ' | sed 's/ $//')

    check_toolchain_origin 'gcc'   "${GCC_VERSIONS:-}"  "${origin_toolchain_ppa}" "${gcc_majors}" \
        'gcc-%s g++-%s'
    check_toolchain_origin 'clang' "${LLVM_VERSIONS:-}" "${origin_llvm}"          "${clang_majors}" \
        'clang-%s libc++-%s-dev libc++abi-%s-dev'

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
