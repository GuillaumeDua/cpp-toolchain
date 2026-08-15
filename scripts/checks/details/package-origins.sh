#!/bin/bash
set -uo pipefail

# See docs/IMAGES_VALIDATION.md

this_script_name=$(basename "$0")
this_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# The installers own how their packages are named, so they answer what is installed.
install_scripts_dir="${this_script_dir}/../../install"

# One level up: the standard library probe is standalone, it is not a detail of this gate.
stdlibs_script="${this_script_dir}/../cxx-stdlibs.sh"

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
        return
    fi

    # dpkg's own status file as the only source means the installed version is in no index apt can see.
    # A different fault from "it came from the wrong repository", and one that reads as nonsense unless it is named:
    #   apt.llvm.org publishes rolling snapshots and drops superseded ones,
    #   so a long-cached layer can hold a version its own repository does not serve.
    if [[ "${origin}" == *'/var/lib/dpkg/status'* ]]; then
        fail "[${package}] is installed at a version [${expected}] does not publish - a stale cached layer, rebuild it without cache"
        return
    fi

    fail "[${package}] expected from [${expected}], apt reports:${origin}"
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

# The libc++ packages are discovered rather than named, unlike every other check here.
#
# apt.llvm.org spells them three ways:
#   - libc++1-17t64, across the time_t transition
#   - libc++1-18 and libc++1-19
#   - plain libc++1 from LLVM 20, where the major leaves the name altogether
# A check that wrote one of those down would keep passing on the two it cannot see,
# and `LLVM_VERSIONS` is not always a bare major it could derive the spelling from.
#
# What is invariant is the library, not its package:
#   cxx-stdlibs.sh finds the installed libc++ by reading the shared objects,
#   and dpkg answers which package put each one there.
#   Origin is then asserted on that answer, so this stays correct through a rename it has never seen.
#
# libc++abi has no row of its own - it is reported as the cxxabi of the libc++ that needs it -
# so its package is resolved from that SONAME.
check_libcxx_runtime(){
    local rows
    rows=$(bash "${stdlibs_script}" --stdlib=libc++ --view=library --format=fields 2>/dev/null)

    if [ -z "${rows}" ]; then
        fail "[libc++] no libc++ runtime is installed - this image cannot run what 'clang++ -stdlib=libc++' produces"
        return
    fi

    local path package cxxabi_path cxxabi_package
    while read -r path package; do
        if [ -z "${package}" ] || [ "${package}" = '-' ]; then
            fail "[libc++] [${path}] is installed but no package owns it"
            continue
        fi
        check_origin "${package}" "${origin_llvm}"

        # Its ABI library sits beside it under the matching name, which is how cxx-stdlibs.sh finds the SONAME.
        # The path is asked for rather than the bare name:
        # the same name exists under every llvm-<major> prefix and in the multiarch directory,
        # and only the copy beside this libc++ is the one that will be loaded with it.
        cxxabi_path="${path/libc++.so/libc++abi.so}"
        cxxabi_package=$(dpkg -S "${cxxabi_path}" 2>/dev/null | head -n 1 | sed 's/:.*//')
        if [ -z "${cxxabi_package}" ]; then
            fail "[libc++abi] no package owns [${cxxabi_path}], which [${package}] needs at load time"
            continue
        fi
        check_origin "${cxxabi_package}" "${origin_llvm}"
    done < <(sed -n 's/.* path=\([^ ]*\).* package=\([^ ]*\).*/\1 \2/p' <<< "${rows}")
}

check_runtime_libraries(){
    [ -r "${stdlibs_script}" ] \
      || die "cannot find cxx-stdlibs.sh one level above scripts/checks/details"

    check_origin 'libstdc++6' "${origin_toolchain_ppa}"
    check_origin 'libgcc-s1'  "${origin_toolchain_ppa}"
    check_libcxx_runtime
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
