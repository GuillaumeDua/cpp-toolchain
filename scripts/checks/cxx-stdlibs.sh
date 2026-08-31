#!/bin/bash

set -uo pipefail

# =============================================================================================
# This file is part of https://github.com/GuillaumeDua/cpp-toolchain
# License: see https://github.com/GuillaumeDua/cpp-toolchain/blob/main/LICENSE
# =============================================================================================

this_script_name=$(basename "$0")

arg_view=''
arg_stdlib='all'
arg_format='default'
arg_compilers=0
arg_compilers_value='all'

default_view='library'
default_stdlib='all'
default_format='default'
default_compilers='all'

die() { echo "[${this_script_name}] error: $*" >&2; exit 1; }

help(){
    echo "Usage: ${this_script_name} [--view=<view>] [--stdlib=<impl>] [--compilers[=<list>]] [--format=<format>]" 1>&2
    echo "
    [ --view ]      = library|compiler|all     What is installed, what compilers reach, or both.
                                               Default [${default_view}]; [compiler] when --compilers is named.
    [ --stdlib ]    = all|libstdc++|libc++     Which implementation -> default is [${default_stdlib}]
    [ --compilers ] = all|'<cxx> <cxx> ...'    Which compilers to ask -> default is [${default_compilers}]
                                               Selects the compiler view. The value needs its '=',
                                               as an optional value always does: written apart it
                                               would be indistinguishable from the next option.
    [ --format ]    = default|fields           Every field. 'fields' tags each line with its view.
                    = name|version|soname|abi  One field per line, deduplicated, and one view only:
                                               --view=all is refused, 'soname' has no compiler answer.
    [ -h | --help ]                            Display usage/help

    Every field is read out of the binary being described, never out of a -dev package:
        impl version soname path package   an installed runtime
        headers                            the tree a compiler compiles against
        abi    libstdc++  greatest GLIBCXX_ in the ELF - what 'GLIBCXX_3.4.32 not found' names
               libc++     its std::__N inline namespace, reported as LIBCPP_ABI_1
               compiler   the ABI it will produce: LIBCPP_ABI_<n>, or cxx11/cxx03 for libstdc++'s
                          dual ABI - a compile-time choice, so it fails at link time, not at load
        cxxabi libstdc++  greatest CXXABI_ in that same ELF
               libc++     the SONAME of libc++abi, the separate library holding its C++ ABI

        ${this_script_name} --stdlib=libstdc++ --format=abi   ->  GLIBCXX_3.4.35
        ${this_script_name} --stdlib=libc++    --format=abi   ->  LIBCPP_ABI_1

    A field this host cannot answer is [-] rather than a guess, so every line of a view keeps its
    shape: without binutils the SONAME falls back to the file name, and without dpkg libstdc++ has
    no version at all, since only the package records which GCC release built it.

    The library view needs no compiler, no binutils and no headers, so it answers on a runtime-only
    image. Why each field is read where it is, and what the two views are for:
    https://github.com/GuillaumeDua/cpp-toolchain/blob/main/scripts/checks/README.md
    " 1>&2
    exit 0
}

set_view(){
    case "$1" in
        library | compiler | all ) arg_view="$1" ;;
        * ) die "unknown view [$1] - expected one of: library, compiler, all" ;;
    esac
}

set_stdlib(){
    case "$1" in
        all | libstdc++ | libc++ ) arg_stdlib="$1" ;;
        * ) die "unknown stdlib [$1] - expected one of: all, libstdc++, libc++" ;;
    esac
}

set_format(){
    case "$1" in
        default | name | version | soname | abi | fields ) arg_format="$1" ;;
        * ) die "unknown format [$1] - expected one of: default, name, version, soname, abi, fields" ;;
    esac
}

# Not validated against a list, unlike the other two: any name on PATH is a legal value, and
# whether it is really there is settled once, below, where a typo can be named in the error.
set_compilers(){
    [ -n "$1" ] \
      || die "option [--compilers] expects a value - drop the '=' entirely for [${default_compilers}]"
    arg_compilers_value="$1"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --compilers=* ) arg_compilers=1; set_compilers "${1#*=}" ;;
        --compilers )   arg_compilers=1 ;;
        --view=* )    set_view "${1#*=}" ;;
        --view )
            [ $# -ge 2 ] || die "option [--view] expects a value"
            set_view "$2"
            shift
            ;;
        --stdlib=* )  set_stdlib "${1#*=}" ;;
        --stdlib )
            [ $# -ge 2 ] || die "option [--stdlib] expects a value"
            set_stdlib "$2"
            shift
            ;;
        --format=* )  set_format "${1#*=}" ;;
        --format )
            [ $# -ge 2 ] || die "option [--format] expects a value"
            set_format "$2"
            shift
            ;;
        -h | --help ) help ;;
        -* )          die "unknown option [$1]" ;;
        * )           die "unexpected argument [$1] - compilers are a value of [--compilers], as in --compilers='$1'" ;;
    esac
    shift
done

# A view is what the compiler list filters, so naming compilers selects that view rather than
# adding it to the default one: the two answer different questions, and a caller asking after a
# compiler is not thereby asking what else is installed. --view=all is how both are asked at once.
if [ -z "${arg_view}" ]; then
    [ "${arg_compilers}" -eq 1 ] && arg_view='compiler' || arg_view="${default_view}"
elif [ "${arg_compilers}" -eq 1 ] && [ "${arg_view}" = 'library' ]; then
    die "option [--compilers] filters the compiler view, which [--view=library] leaves out"
fi

# A narrowing format prints one field and nothing that says which view produced it, so it can
# only speak for one. Asked of both, it would deduplicate the answers to two different questions
# into a single list - a runtime's GLIBCXX_ beside a compiler's dual-ABI choice - and no caller
# could tell them apart afterwards.
case "${arg_format}" in
    default | fields ) ;;
    * ) [ "${arg_view}" != 'all' ] \
          || die "format [${arg_format}] answers for one view - pass --view=library or --view=compiler" ;;
esac

# A compiler reports the headers it reaches, not a library, and headers have no SONAME.
# There is nothing to narrow to, so this is refused instead of answered with empty output.
[ "${arg_format}" != 'soname' ] || [ "${arg_view}" != 'compiler' ] \
  || die "format [soname] has no meaning for [--view=compiler] - a compiler names headers, not a library"

# Named compilers are a promise the host has to keep: a typo must fail here rather than quietly
# report one row fewer than was asked for.
named_compilers=()
if [ "${arg_compilers}" -eq 1 ] && [ "${arg_compilers_value}" != 'all' ]; then
    read -r -a named_compilers <<< "${arg_compilers_value}"

    for cxx in "${named_compilers[@]}"; do
        command -v "${cxx}" >/dev/null 2>&1 \
          || die "compiler '${cxx}' not found in PATH"
    done
fi

# dpkg owns the only place a libc++ release is written down: its ELF carries no version and
# its SONAME never moves, so the package version is what distinguishes libc++ 20 from 22.
has_dpkg=0
command -v dpkg-query >/dev/null 2>&1 && has_dpkg=1

# Matches the header spelling '#  define X 1' as well as the preprocessed '#define X 1'.
# Takes the field after the name rather than the last on the line: a define left without a value
# would otherwise report its own name as the value, and a trailing comment would report the
# comment. Neither input carries comments today - a preprocessor strips them and the two headers
# read here have none - but the value of a macro is the token after it either way.
defined_value(){
    awk -v name="$1" '
        $0 ~ "^#[ \t]*define[ \t]+" name "([ \t]|$)" {
            for (i = 1; i <= NF; i++)
                if ($i == name) { print $(i + 1); exit }
        }
    '
}

# _LIBCPP_VERSION packs the release as MMmmpp, so 220108 is 22.1.8. libc++ 15 and earlier packed
# it in fewer digits, and running those through this arithmetic would turn 15000 into '1.50.0' -
# a wrong answer that reads like a right one. Only the six-digit form is decoded; anything else
# is handed back as the macro itself, which is at least recognizably raw.
dotted_libcpp_version(){
    case "$1" in
        [0-9][0-9][0-9][0-9][0-9][0-9] ) ;;
        * ) printf '%s' "$1"; return ;;
    esac

    printf '%d.%d.%d' "$((10#$1 / 10000))" "$(((10#$1 / 100) % 100))" "$((10#$1 % 100))"
}

# ldconfig reports what the runtime linker will actually resolve, which is the answer that
# matters. The globs cover an image whose cache was never built, and the llvm-* one covers
# the versioned libc++ that apt.llvm.org keeps outside the multiarch directory.
discover_library_files(){
    {
        ldconfig -p 2>/dev/null | sed -n 's/.* => //p'
        ls -1 /usr/lib/libstdc++.so.[0-9]*        /usr/lib/libc++.so.[0-9]*        \
              /usr/lib/*/libstdc++.so.[0-9]*      /usr/lib/*/libc++.so.[0-9]*      \
              /usr/lib/llvm-*/lib/libc++.so.[0-9]* 2>/dev/null
    } | grep -E '/lib(stdc\+\+|c\+\+)\.so\.[0-9]'
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

# The same question as max_symbol_version, asked of libc++, which carries no GNU symbol versions and
# states its ABI in an inline namespace instead - scripts/checks/README.md covers the mangling, and
# why the match has to stop after one digit.
libcpp_abi_from_elf(){
    local found
    found=$(LC_ALL=C grep -aoE 'St3__[0-9]' "$1" 2>/dev/null | sort -u)

    # No match and more than one match both hand the question to the headers: a two-digit ABI
    # (St4__10) or a renamed namespace (__ndk1) never matches, and two matches are ambiguous.
    [ -n "${found}" ] || return
    [ "$(printf '%s\n' "${found}" | wc -l)" -eq 1 ] || return

    printf '%s' "${found#St3__}"
}

package_of(){
    [ "${has_dpkg}" -eq 1 ] || { printf '%s' '-'; return; }

    local package
    package=$(dpkg -S "$1" 2>/dev/null | head -n 1 | sed 's/:.*//')
    printf '%s' "${package:--}"
}

# Debian versions carry an epoch and a revision around the upstream release,
# and only the release in the middle is what a C++ developer calls the version.
version_of_package(){
    [ "$1" != '-' ] || { printf '%s' '-'; return; }

    local version
    version=$(dpkg-query -W -f='${Version}' "$1" 2>/dev/null)
    version="${version#*:}"
    version="${version%%[-~]*}"
    printf '%s' "${version:--}"
}

# The header tree belonging to one libc++ runtime: beside it under an llvm-<major> prefix, or
# the system one for the copy in the multiarch directory. A tree is trusted only when its own
# _LIBCPP_VERSION agrees with the package's, so a runtime installed without its headers - which
# is every libc++1-<major> package - reports nothing instead of borrowing another release's ABI.
libcpp_headers_for(){
    local real="$1" version="$2" directory candidate raw
    directory="${real%/*}"

    # Exactly one tree can belong to a library, and which one is decided by where the library
    # sits: a runtime under an llvm-<major> prefix owns the tree beside it and nothing else.
    # Falling back to the system tree here would label the copy of libc++ 20 that also lives in
    # the multiarch directory with libc++ 22's version, which is the release it is not.
    case "${directory}" in
        */lib ) candidate="${directory%/lib}/include/c++/v1" ;;
        * )     candidate='/usr/include/c++/v1' ;;
    esac

    # Tested before the redirection rather than after: a redirection that cannot open its file
    # is reported by the shell itself, which no redirection on the command can silence.
    [ -r "${candidate}/__config" ] || return

    raw=$(defined_value _LIBCPP_VERSION < "${candidate}/__config")
    [ -n "${raw}" ] || return

    [ "${version}" = '-' ] \
      || [ "$(dotted_libcpp_version "${raw}")" = "${version}" ] \
      || return

    printf '%s' "${candidate}"
}

# One '<impl> <version> <soname> <realpath> <abi> <cxxabi> <package>' row per library.
# Files are resolved before anything else so that /lib and /usr/lib, which are the same
# directory on a merged-usr host, cannot produce the same library twice.
library_rows(){
    local file real impl version soname abi cxxabi package headers
    local -A seen_path=()
    local -A seen_package=()

    while read -r file; do
        real=$(readlink -f "${file}" 2>/dev/null)
        [ -f "${real}" ] || continue
        [ -z "${seen_path[${real}]:-}" ] || continue
        seen_path[${real}]=1

        case "${real}" in
            *libstdc++.so.* ) impl='libstdc++' ;;
            *libc++.so.*    ) impl='libc++' ;;
            * )               continue ;;
        esac

        package=$(package_of "${real}")

        # apt.llvm.org ships the same runtime twice, once under llvm-<major> and once in the
        # multiarch directory, as two files rather than a link - one package is one row.
        if [ "${package}" != '-' ]; then
            [ -z "${seen_package[${package}]:-}" ] || continue
            seen_package[${package}]=1
        fi

        soname=$(soname_of "${real}")
        version=$(version_of_package "${package}")

        if [ "${impl}" = 'libstdc++' ]; then
            abi=$(max_symbol_version "${real}" 'GLIBCXX')
            cxxabi=$(max_symbol_version "${real}" 'CXXABI')
        else
            # The runtime states its own ABI in every symbol it exports, so that is where a row
            # reads it. The headers are only the fallback: they ship in a -dev package that need
            # not be installed, and need not be the one this .so came from.
            abi=$(libcpp_abi_from_elf "${real}")
            headers=$(libcpp_headers_for "${real}" "${version}")

            if [ -n "${headers}" ]; then
                [ "${version}" != '-' ] \
                  || version=$(dotted_libcpp_version "$(defined_value _LIBCPP_VERSION < "${headers}/__config")")

                # Only where the binary stayed silent. libc++ spells the macro out just when it is
                # not the default, so a tree that was read and said nothing means ABI 1.
                if [ -z "${abi}" ]; then
                    [ -r "${headers}/__config_site" ] \
                      && abi=$(defined_value _LIBCPP_ABI_VERSION < "${headers}/__config_site")
                    abi="${abi:-1}"
                fi
            fi

            [ -z "${abi}" ] || abi="LIBCPP_ABI_${abi}"
            abi="${abi:--}"
            cxxabi=$(soname_of "${real/libc++.so/libc++abi.so}")
        fi

        printf '%s %s %s %s %s %s %s\n' \
            "${impl}" "${version}" "${soname}" "${real}" "${abi}" "${cxxabi}" "${package}"
    done < <(discover_library_files)
}

discover_compilers(){
    local candidate
    while read -r candidate; do
        command -v "${candidate}" >/dev/null 2>&1 && printf '%s\n' "${candidate}"
    done < <(compgen -c 2>/dev/null | grep -E '^(g\+\+|clang\+\+)(-[0-9]+)?$' | sort -u)
}

# -E -dD rather than -dM -E: the line markers come with the macros, so one pass yields both
# what the compiler compiles against and where it found it.
probe_compiler(){
    local cxx="$1"
    shift

    local out version impl abi headers
    out=$(echo '#include <cstddef>' | "${cxx}" "$@" -xc++ -E -dD - 2>/dev/null)
    [ -n "${out}" ] || return 1

    version=$(defined_value _LIBCPP_VERSION <<< "${out}")
    if [ -n "${version}" ]; then
        impl='libc++'
        # Spelled and defaulted exactly as the library view spells and defaults it: this is the
        # same _LIBCPP_ABI_VERSION, and two views reporting one fact two ways reads as two facts.
        abi=$(defined_value _LIBCPP_ABI_VERSION <<< "${out}")
        abi="LIBCPP_ABI_${abi:-1}"
        version=$(dotted_libcpp_version "${version}")
    else
        version=$(defined_value _GLIBCXX_RELEASE <<< "${out}")
        [ -n "${version}" ] || return 1
        impl='libstdc++'
        # The dual ABI is the one libstdc++ choice that silently breaks linking between two
        # objects built from the same headers, so it is the ABI worth reporting here.
        [ "$(defined_value _GLIBCXX_USE_CXX11_ABI <<< "${out}")" = '1' ] \
          && abi='cxx11' || abi='cxx03'
    fi

    # Compilers spell the same directory differently, reaching it through their own prefix -
    # resolving it is what lets two of them be compared at a glance.
    headers=$(grep -m 1 -oP '(?<=")[^"]*/cstddef(?=")' <<< "${out}")
    headers=$(readlink -f "${headers%/cstddef}" 2>/dev/null)

    printf '%s %s %s %s %s\n' "${cxx}" "${impl}" "${version}" "${abi}" "${headers:--}"
}

# One '<compiler> <impl> <version> <abi> <headers>' row per compiler and stdlib it accepts.
compiler_rows(){
    local cxx
    local -a compilers=()

    if [ "${arg_compilers_value}" = 'all' ]; then
        mapfile -t compilers < <(discover_compilers)
    else
        compilers=("${named_compilers[@]}")
    fi

    for cxx in "${compilers[@]}"; do
        probe_compiler "${cxx}"
        probe_compiler "${cxx}" -stdlib=libc++
    done
}

keep_selected(){
    [ "${arg_stdlib}" = 'all' ] && { cat; return; }
    awk -v impl="${arg_stdlib}" -v column="$1" '$column == impl'
}

render_libraries(){
    case "${arg_format}" in
        default ) awk '{ printf "%s %s -> soname=%s abi=%s cxxabi=%s package=%s\n", $1, $2, $3, $5, $6, $7 }' ;;
        name )    awk '{ print $1 }' ;;
        version ) awk '{ print $2 }' ;;
        soname )  awk '{ print $3 }' ;;
        abi )     awk '{ print $5 }' ;;
        fields )  awk '{ printf "view=library impl=%s version=%s soname=%s path=%s abi=%s cxxabi=%s package=%s\n", $1, $2, $3, $4, $5, $6, $7 }' ;;
    esac
}

# No soname arm: a compiler reports what it compiles against, which has no SONAME of its own.
# --format=soname is refused against this view while the arguments are read, so it never lands here.
render_compilers(){
    case "${arg_format}" in
        default ) awk '{ printf "%s -> %s %s abi=%s headers=%s\n", $1, $2, $3, $4, $5 }' ;;
        name )    awk '{ print $2 }' ;;
        version ) awk '{ print $3 }' ;;
        abi )     awk '{ print $4 }' ;;
        fields )  awk '{ printf "view=compiler compiler=%s impl=%s version=%s abi=%s headers=%s\n", $1, $2, $3, $4, $5 }' ;;
    esac
}

render(){
    [ -z "${libraries}" ] || render_libraries <<< "${libraries}"

    # The blank line and the label separate two views sharing one stream, so they belong to
    # --view=all alone, and there only to the format a reader reads: 'fields' tags every line itself.
    if [ -n "${compilers}" ]; then
        [ "${arg_format}" != 'default' ] || [ "${arg_view}" != 'all' ] \
          || printf '\n%s\n' 'compilers:'
        render_compilers <<< "${compilers}"
    fi
}

# Only the selected views are gathered: asking every compiler on a host costs about a minute,
# which is not worth spending on rows nothing is going to print.
# Sorted on the first two columns only, and deliberately without -u: sort would read equal
# keys as duplicate lines and drop the 32-bit runtimes, which share a name and a version with
# the 64-bit one and differ only further along the row. Rows are already unique by then.
libraries=''
[ "${arg_view}" = 'compiler' ] || libraries=$(library_rows | sort -k1,1 -k2,2V)

compilers=''
[ "${arg_view}" = 'library' ] || compilers=$(compiler_rows | sort -k1,1V -k2,2)

# A host that cannot answer the view it was asked for is broken and says so, in the terms of the
# view that came up empty. A --stdlib that selects the one implementation this host does not have
# is a different thing entirely - an empty answer, not a failure - which is why this is asked
# before the filter rather than after it.
if [ -z "${libraries}" ] && [ -z "${compilers}" ]; then
    case "${arg_view}" in
        library )  die "no C++ standard library found - looked at ldconfig, /usr/lib and, where present, dpkg" ;;
        compiler ) die "no compiler answered - looked for g++ and clang++ on PATH, with and without a version suffix" ;;
        all )      die "nothing found - looked at ldconfig, /usr/lib and dpkg for libraries, and at PATH for compilers" ;;
    esac
fi

# Guarded, because a here-string feeds an empty variable through as one empty line.
[ -z "${libraries}" ] || libraries=$(keep_selected 1 <<< "${libraries}")
[ -z "${compilers}" ] || compilers=$(keep_selected 2 <<< "${compilers}")

case "${arg_format}" in
    default | fields ) render ;;
    # A narrowed line keeps one field and drops whatever else made two rows distinct, so the
    # survivors are deduplicated: three libstdc++ runtimes built for three architectures are one
    # answer to --format=version. Within a single view only, which is all these formats are asked of.
    * ) render | awk '!seen[$0]++' ;;
esac

exit 0
