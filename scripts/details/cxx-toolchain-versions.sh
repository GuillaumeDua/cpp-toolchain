#!/bin/bash
set -uo pipefail

# =============================================================================================
# This file is part of https://github.com/GuillaumeDua/cpp-toolchain
# License: see https://github.com/GuillaumeDua/cpp-toolchain/blob/main/LICENSE
# =============================================================================================

# What a published image carries where a pin cannot say: its distribution point release, its
# compilers and its standard library implementations, as `key=value` lines, the shape
# cxx-stdlibs.sh already reports in.
#
# Runs *inside* an image, over a bind-mounted scripts/ - the published stages carry no checks,
# and these versions are knowable nowhere else: GCC and Clang pin a major and install from
# rolling apt sources, and the standard libraries arrive as dependencies with no ARG at all.
# Every other pin is exact, so collecting it here would restate the Dockerfile.
#
# Usage, from anywhere - the paths resolve against this script:
#     bash cxx-toolchain-versions.sh
#
# It takes no stage: it reports what it finds, so a runtime image answers with standard libraries
# alone and nothing here has to be kept in step with the canonical stage lists.
#
# Keys carry the kind of thing they describe as a prefix - `distribution.`, `compilers.` or
# `libraries.` - because a release note renders each group differently.

this_script_name=$(basename "$0")
this_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# The installers own which majors they put there, and the standard library probe owns how a
# runtime is read out of its ELF. Both are composed, never reimplemented.
install_scripts_dir="${this_script_dir}/../install"
stdlibs_script="${this_script_dir}/../checks/cxx-stdlibs.sh"

die() { echo "[${this_script_name}] error: $*" >&2; exit 1; }

# `-dumpfullversion` on GCC, because `-dumpversion` has reported the major alone since GCC 7.
# Clang has no such split. Both answer the upstream version, unlike dpkg, which reports
# `1:22.1.8~++20260613092238+e80beda6e255-1~exp1~...` for the same compiler.
collect_compilers(){
    local driver="$1" version_flag="$2" lister="$3"
    local major version

    [ -r "${install_scripts_dir}/${lister}" ] \
      || die "cannot find ${lister} one level above scripts/details"

    for major in $(bash "${install_scripts_dir}/${lister}" --list-installed 2>/dev/null); do
        version=$("${driver}-${major}" "${version_flag}" 2>/dev/null)
        [ -n "${version}" ] && echo "compilers.${driver}-${major}=${version}"
    done
}

# Keyed by the package that owns each runtime rather than by implementation: the same one can
# appear twice (an llvm-<major> copy beside a multiarch one), and the package is what tells them
# apart and what a reader can install.
# Both ABI fields get keys of their own, because they move independently of the version beside them
# and of each other, and because which one carries the information differs by implementation:
#   libstdc++  abi is the greatest GLIBCXX_ symbol - `GLIBCXX_3.4.32 not found` is what a consumer
#              hits - and cxxabi the greatest CXXABI_ one.
#   libc++     abi is its inline namespace, reported as LIBCPP_ABI_1, which has not moved; cxxabi is
#              the SONAME of libc++abi, the separate library it needs at load time, which does.
collect_stdlibs(){
    local row pair package
    local -A field

    [ -r "${stdlibs_script}" ] \
      || die "cannot find cxx-stdlibs.sh one level above scripts/details"

    while IFS= read -r row; do
        field=()
        for pair in ${row}; do
            field["${pair%%=*}"]="${pair#*=}"
        done

        package="${field[package]:--}"
        [ "${package}" = '-' ] && continue

        [ "${field[version]:--}" != '-' ] && echo "libraries.${package}=${field[version]}"
        [ "${field[abi]:--}"     != '-' ] && echo "libraries.${package}-abi=${field[abi]}"
        [ "${field[cxxabi]:--}"  != '-' ] && echo "libraries.${package}-cxxabi=${field[cxxabi]}"
    done < <(bash "${stdlibs_script}" --view=library --format=fields 2>/dev/null)
}

# The point release, which the pin cannot state: `ubuntu:24.04` is a rolling tag, and VERSION_ID
# restates it, while VERSION carries the `24.04.3` the base image was built from.
# /etc/os-release rather than lsb_release, which needs a package a minimal image has no reason to
# carry. Sourced in a subshell: it sets NAME, VERSION and ID in whatever shell reads it.
collect_distribution(){
    [ -r /etc/os-release ] || return 0
    (
        . /etc/os-release
        [ "${ID:-}" = 'ubuntu' ] && [ -n "${VERSION:-}" ] && echo "distribution.ubuntu=${VERSION%% *}"
    )
}

[ $# -eq 0 ] || die "usage: ${this_script_name}  (no arguments - it reports what it finds)"

{
    collect_distribution
    collect_compilers gcc   -dumpfullversion gcc.sh
    collect_compilers clang -dumpversion     llvm.sh
    collect_stdlibs
} | sort
