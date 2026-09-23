#!/bin/bash

set -uo pipefail

# =============================================================================================
# This file is part of https://github.com/GuillaumeDua/cpp-toolchain
# License: see https://github.com/GuillaumeDua/cpp-toolchain/blob/main/LICENSE
# =============================================================================================

this_script_name=$(basename "$0")

arg_format='default'

default_format='default'

die() { echo "[${this_script_name}] error: $*" >&2; exit 1; }

help(){
    echo "Usage: ${this_script_name} [--format=<format>]" 1>&2
    echo "
    [ --format ]    = default|fields           Every field. 'fields' tags each line with its view.
                    = version|abi              One field per line, deduplicated.
    [ -h | --help ]                            Display usage/help

    Every field is read out of the binary being described, never out of a -dev package:
        impl version soname path package   an installed runtime
        abi                                greatest GLIBC_ in the ELF - what 'GLIBC_2.38 not found' names

        ${this_script_name} --format=abi       ->  GLIBC_2.39
        ${this_script_name} --format=version   ->  2.39

    version and abi answer two questions that usually give the same number: what is installed, and
    the newest contract it offers. A release that adds no symbol leaves abi one release behind.

    A field this host cannot answer is [-] rather than a guess, so every line keeps its shape:
    without binutils the SONAME falls back to the file name, and without dpkg there is no version,
    since only the package records the release.

    This view needs no compiler, no binutils and no headers, so it answers on a runtime-only image.
    The C++ counterpart, and why each field is read where it is:
    https://github.com/GuillaumeDua/cpp-toolchain/blob/main/scripts/checks/README.md
    " 1>&2
    exit 0
}

# No --view and no --stdlib, unlike cxx-stdlibs.sh: there is one view here, and glibc is the one
# implementation these images carry. A flag with a single legal value answers nothing.
set_format(){
    case "$1" in
        default | version | abi | fields ) arg_format="$1" ;;
        * ) die "unknown format [$1] - expected one of: default, version, abi, fields" ;;
    esac
}

while [ $# -gt 0 ]; do
    case "$1" in
        --format=* )  set_format "${1#*=}" ;;
        --format )
            [ $# -ge 2 ] || die "option [--format] expects a value"
            set_format "$2"
            shift
            ;;
        -h | --help ) help ;;
        -* )          die "unknown option [$1]" ;;
        * )           die "unexpected argument [$1] - this script takes options only" ;;
    esac
    shift
done

has_dpkg=0
command -v dpkg-query >/dev/null 2>&1 && has_dpkg=1

# ldconfig reports what the runtime linker will actually resolve, which is the answer that
# matters. The globs cover an image whose cache was never built, /usr/lib32 and /usr/libx32
# included: the secondary ABIs live outside the multiarch directory.
# 'libc.so.' rather than 'libc*.so.': libc++.so.1 must not land here.
discover_library_files(){
    {
        ldconfig -p 2>/dev/null | sed -n 's/.* => //p'
        ls -1 /usr/lib/libc.so.[0-9]*    /usr/lib/*/libc.so.[0-9]*    \
              /usr/lib32/libc.so.[0-9]*  /usr/libx32/libc.so.[0-9]*   2>/dev/null
    } | grep -E '/libc\.so\.[0-9]'
}

# binutils reads the SONAME straight out of the ELF. A runtime image ships none of it, so the name
# up to the major stands in - an approximation, whose limits scripts/checks/README.md states.
soname_of(){
    [ -f "$1" ] || { printf '%s' '-'; return; }

    local soname=''
    command -v objdump >/dev/null 2>&1 \
      && soname=$(objdump -p "$1" 2>/dev/null | awk '$1 == "SONAME" { print $2; exit }')

    [ -n "${soname}" ] \
      || { command -v readelf >/dev/null 2>&1 \
        && soname=$(readelf -d "$1" 2>/dev/null \
          | sed -n 's/.*SONAME.*\[\(.*\)\].*/\1/p' | head -n 1); }

    [ -n "${soname}" ] \
      || soname=$(sed 's|.*/||; s|\(\.so\.[0-9][0-9]*\).*|\1|' <<< "$1")

    printf '%s' "${soname:--}"
}

# The greatest symbol version an ELF exposes. readelf is the direct read, but a runtime image
# ships no binutils, and grepping the binary for the same strings agrees with it exactly.
max_symbol_version(){
    local found=''
    command -v readelf >/dev/null 2>&1 \
      && found=$(readelf --version-info "$1" 2>/dev/null \
        | grep -oE "$2_[0-9][0-9.]*" | sort -uV | tail -n 1)

    [ -n "${found}" ] \
      || found=$(LC_ALL=C grep -ao "$2_[0-9][0-9.]*" "$1" 2>/dev/null | sort -uV | tail -n 1)

    printf '%s' "${found:--}"
}

package_of(){
    [ "${has_dpkg}" -eq 1 ] || { printf '%s' '-'; return; }

    local package
    package=$(dpkg -S "$1" 2>/dev/null | head -n 1 | sed 's/:.*//')
    printf '%s' "${package:--}"
}

# Debian versions carry an epoch and a revision around the upstream release,
# and only the release in the middle is what a C developer calls the version.
version_of_package(){
    [ "$1" != '-' ] || { printf '%s' '-'; return; }

    local version
    version=$(dpkg-query -W -f='${Version}' "$1" 2>/dev/null)
    version="${version#*:}"
    version="${version%%[-~]*}"
    printf '%s' "${version:--}"
}

library_rows(){
    local file real soname version abi package
    local -A seen_path=()
    local -A seen_package=()

    while read -r file; do
        real=$(readlink -f "${file}" 2>/dev/null)
        [ -f "${real}" ] || continue
        [ -z "${seen_path[${real}]:-}" ] || continue
        seen_path[${real}]=1

        # One package is one row: the secondary ABIs ship their own libc.so.6, and the package is
        # what tells them apart and what a reader can install.
        package=$(package_of "${real}")
        if [ "${package}" != '-' ]; then
            [ -z "${seen_package[${package}]:-}" ] || continue
            seen_package[${package}]=1
        fi

        soname=$(soname_of "${real}")
        version=$(version_of_package "${package}")
        abi=$(max_symbol_version "${real}" 'GLIBC')

        printf '%s %s %s %s %s %s\n' 'glibc' "${version}" "${soname}" "${real}" "${abi}" "${package}"
    done < <(discover_library_files)
}

# 'view=library' is emitted although this script has only one: a caller reading both scripts into
# one stream - scripts/details/cxx-toolchain-versions.sh does - parses every line the same way.
render(){
    case "${arg_format}" in
        default ) awk '{ printf "%s %s -> soname=%s abi=%s package=%s\n", $1, $2, $3, $5, $6 }' ;;
        version ) awk '{ print $2 }' ;;
        abi )     awk '{ print $5 }' ;;
        fields )  awk '{ printf "view=library impl=%s version=%s soname=%s path=%s abi=%s package=%s\n", $1, $2, $3, $4, $5, $6 }' ;;
    esac
}

# Sorted on the package, which is the only column that distinguishes two rows: the secondary ABIs
# share a name and a version with the primary one. Deliberately without -u, for that same reason.
libraries=$(library_rows | sort -k6,6)

[ -n "${libraries}" ] \
  || die "no C standard library found - looked at ldconfig, /usr/lib and, where present, dpkg"

case "${arg_format}" in
    default | fields ) render <<< "${libraries}" ;;
    # A narrowed line keeps one field and drops whatever else made two rows distinct, so the
    # survivors are deduplicated: three glibc runtimes built for three ABIs are one answer to
    # --format=version.
    * ) render <<< "${libraries}" | awk '!seen[$0]++' ;;
esac

exit 0
