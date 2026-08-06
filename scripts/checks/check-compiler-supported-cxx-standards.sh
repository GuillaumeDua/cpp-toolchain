#!/bin/bash
set -uo pipefail

# See docs/IMAGES_VALIDATION.md

this_script_name=$(basename "$0")

arg_stable=0
arg_greatest=0
arg_cxx='g++'

die() { echo "error: $*" >&2; exit 1; }

help(){
    echo "Usage: ${this_script_name} [--stable] [--greatest] [compiler]" 1>&2
    echo "
        [ --stable ]    : Only final standards, dropping draft spellings such as c++2c.
        [ --greatest ]  : Print the highest standard alone, as a bare token. Ex: 'c++26'
        [ -h | --help ] : Display usage/help
        [ compiler ]    : The C++ compiler to probe -> default is [g++]

    Without --greatest, every detected standard is reported as '<std> -> __cplusplus=<value>',
    ordered by increasing __cplusplus.
    " 1>&2
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --stable )    arg_stable=1 ;;
        --greatest )  arg_greatest=1 ;;
        -h | --help ) help ;;
        -* )          die "unknown option [$1]" ;;
        * )           arg_cxx="$1" ;;
    esac
    shift
done

command -v "${arg_cxx}" >/dev/null 2>&1 \
  || die "compiler '${arg_cxx}' not found in PATH"

echo | "${arg_cxx}" -xc++ -E - >/dev/null 2>&1 \
  || die "'${arg_cxx}' exists but failed to run as a C++ compiler"

# Clang-style discovery: valid values are quoted in the -std error.
discovery_error=$(echo | "${arg_cxx}" -std=blah -xc++ -c - 2>&1)
spellings=$(printf '%s\n' "${discovery_error}" \
  | grep -oP "(?<=')(c|gnu)\+\+\w+(?=')" | grep -v gnu | sort -u)

# GCC-style fallback: scrape -v --help.
if [ -z "${spellings}" ]; then
  spellings=$("${arg_cxx}" -v --help 2>&1 \
    | grep -oP '(?<=-std=)(c\+\+\w+)' | grep -v gnu | sort -u)
fi

[ -n "${spellings}" ] \
  || die "could not discover any C++ standard for '${arg_cxx}'"

# Draft spellings such as c++2c share a __cplusplus value with the final name they anticipate,
# so ties are resolved in favour of the final one.
is_final_spelling(){ [[ "$1" =~ ^c\+\+[0-9]{2}$ ]]; }

detected=()
for spelling in ${spellings}; do  # word splitting is intended: one spelling per line
    value=$(echo | "${arg_cxx}" -std="${spelling}" -xc++ -dM -E - 2>/dev/null \
      | grep -oP '(?<=__cplusplus )\d+')
    [ -n "${value}" ] || continue

    if is_final_spelling "${spelling}"; then
        detected+=("${value} 1 ${spelling}")
    else
        detected+=("${value} 0 ${spelling}")
    fi
done

[ "${#detected[@]}" -gt 0 ] \
  || die "'${arg_cxx}' accepted no C++ standard (none produced __cplusplus)"

standards=$(printf '%s\n' "${detected[@]}")

if [ "${arg_stable}" -eq 1 ]; then
    standards=$(printf '%s\n' "${standards}" | awk '$2 == 1')
    [ -n "${standards}" ] \
      || die "'${arg_cxx}' exposes no final C++ standard spelling, only drafts"
fi

standards=$(printf '%s\n' "${standards}" | sort -k1,1n -k2,2n)

if [ "${arg_greatest}" -eq 1 ]; then
    printf '%s\n' "${standards}" | tail -n 1 | awk '{ print $3 }'
else
    printf '%s\n' "${standards}" | awk '{ printf "%s -> __cplusplus=%s\n", $3, $1 }'
fi

exit 0
