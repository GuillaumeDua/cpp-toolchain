#!/bin/bash
set -uo pipefail

# See docs/IMAGES_VALIDATION.md

this_script_name=$(basename "$0")

arg_stable=0
arg_greatest=0
arg_format='default'
arg_cxx=''

default_cxx='g++'

die() { echo "[${this_script_name}] error: $*" >&2; exit 1; }

help(){
    echo "Usage: ${this_script_name} [--stable] [--greatest] [--format=<format>] [compiler]" 1>&2
    echo "
    Which standards are reported:
        [ --stable ]    : Only final standards, dropping draft spellings such as c++2c.
        [ --greatest ]  : Only the highest standard, the one with the greatest __cplusplus.

    How they are reported - one line each:
        [ --format ]    : default   : Both fields, and the default. Ex: 'c++23 -> __cplusplus=202302'
                          std       : The standard spelling alone.  Ex: 'c++23'
                          cplusplus : The __cplusplus value alone.  Ex: '202302'

        [ -h | --help ] : Display usage/help
        [ compiler ]    : The C++ compiler to probe -> default is [${default_cxx}]

    Standards are ordered by increasing __cplusplus, never by the flag name: as text or as
    versions, 98 is greater than 26 and c++98 would sort last.

    --format=std is spelled as the compiler spells it, so it can be fed straight back to it:
        ${this_script_name} --greatest --stable --format=std g++-16   ->  c++26
    " 1>&2
    exit 0
}

set_format(){
    case "$1" in
        default | std | cplusplus ) arg_format="$1" ;;
        * ) die "unknown format [$1] - expected one of: default, std, cplusplus" ;;
    esac
}

while [ $# -gt 0 ]; do
    case "$1" in
        --stable )    arg_stable=1 ;;
        --greatest )  arg_greatest=1 ;;
        --format=* )  set_format "${1#*=}" ;;
        --format )
            [ $# -ge 2 ] || die "option [--format] expects a value"
            set_format "$2"
            shift
            ;;
        -h | --help ) help ;;
        -* )          die "unknown option [$1]" ;;
        * )
            [ -z "${arg_cxx}" ] \
              || die "only one compiler can be probed, got [${arg_cxx}] then [$1]"
            arg_cxx="$1"
            ;;
    esac
    shift
done

arg_cxx="${arg_cxx:-${default_cxx}}"

command -v "${arg_cxx}" >/dev/null 2>&1 \
  || die "compiler '${arg_cxx}' not found in PATH"

echo | "${arg_cxx}" -xc++ -E - >/dev/null 2>&1 \
  || die "'${arg_cxx}' exists but failed to run as a C++ compiler"

# Clang quotes every valid value in the error it raises for an invalid one,
# GCC does not and has to be scraped from its help instead.
# Both patterns anchor on what precedes the value, which is what leaves the gnu++ spellings out.
discover_spellings(){
    local spellings
    spellings=$(echo | "${arg_cxx}" -std=blah -xc++ -c - 2>&1 \
      | grep -oP "(?<=')c\+\+\w+(?=')" | sort -u)

    [ -n "${spellings}" ] \
      || spellings=$("${arg_cxx}" -v --help 2>&1 \
        | grep -oP '(?<=-std=)c\+\+\w+' | sort -u)

    [ -n "${spellings}" ] && printf '%s\n' "${spellings}"
}

cplusplus_value_of(){
    echo | "${arg_cxx}" -std="$1" -xc++ -dM -E - 2>/dev/null \
      | grep -oP '(?<=__cplusplus )\d+'
}

# Draft spellings such as c++2c share a __cplusplus value with the final name they anticipate,
# so ties are resolved in favour of the final one: it ranks second and sorting puts it last.
is_final_spelling(){ [[ "$1" =~ ^c\+\+[0-9]{2}$ ]]; }

mapfile -t spellings < <(discover_spellings)
[ "${#spellings[@]}" -gt 0 ] \
  || die "could not discover any C++ standard for '${arg_cxx}'"

# One '<__cplusplus> <rank> <spelling>' row per accepted standard.
detected=()
for spelling in "${spellings[@]}"; do
    value=$(cplusplus_value_of "${spelling}")
    [ -n "${value}" ] || continue

    rank=0
    is_final_spelling "${spelling}" && rank=1

    detected+=("${value} ${rank} ${spelling}")
done

[ "${#detected[@]}" -gt 0 ] \
  || die "'${arg_cxx}' accepted no C++ standard (none produced __cplusplus)"

standards=$(printf '%s\n' "${detected[@]}")

if [ "${arg_stable}" -eq 1 ]; then
    standards=$(awk '$2 == 1' <<< "${standards}")
    [ -n "${standards}" ] \
      || die "'${arg_cxx}' exposes no final C++ standard spelling, only drafts"
fi

standards=$(sort -k1,1n -k2,2n <<< "${standards}")

if [ "${arg_greatest}" -eq 1 ]; then
    standards=$(tail -n 1 <<< "${standards}")
fi

# Spellings are all distinct, __cplusplus values are not: c++98 and c++03 both report 199711,
# and a draft repeats the value of the final name it anticipates.
case "${arg_format}" in
    default )   awk '{ printf "%s -> __cplusplus=%s\n", $3, $1 }' <<< "${standards}" ;;
    std )       awk '{ print $3 }'                                <<< "${standards}" ;;
    cplusplus ) awk '!seen[$1]++ { print $1 }'                    <<< "${standards}" ;;
esac

exit 0
