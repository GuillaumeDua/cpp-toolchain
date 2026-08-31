#!/bin/bash
set -uo pipefail

# See docs/IMAGES_VALIDATION.md

this_script_name=$(basename "$0")
this_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

stdlibs_script="${this_script_dir}/../cxx-stdlibs.sh"

failures=0

die()  { echo "[${this_script_name}] error: $*" >&2; exit 1; }
fail() { echo "[${this_script_name}] FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "[${this_script_name}] ok:   $*"; }

# What this image has, as '<impl> <soname> <version> <abi>', one line per distinct SONAME.
#   The SONAME is the key rather than the package or the path: it is what the linker writes into a
#   binary and the only name the loader looks up, so it is the field that decides whether a binary loads.
#   Two consequences the callers below rely on: side-by-side libc++ releases, covered in
#   scripts/checks/README.md, and multilib collapsing into one row, covered in docs/IMAGES_VALIDATION.md.
current_rows(){
    bash "${stdlibs_script}" --view=library --format=fields 2>/dev/null                     \
      | awk '{
            delete field
            for (i = 1; i <= NF; i++) {
                separator = index($i, "=")
                field[substr($i, 1, separator - 1)] = substr($i, separator + 1)
            }
            if (field["impl"] != "") print field["impl"], field["soname"], field["version"], field["abi"]
        }'                                                                                  \
      | sort -u
}

# One SONAME answered by two releases is reported, not resolved:
#   which of them a binary gets is the loader's decision, not this image's,
#   so neither side of the comparison below would mean anything.
# Where that can arise, and why multilib does not trip it, is in docs/IMAGES_VALIDATION.md.
check_unambiguous(){
    local rows="$1"
    local duplicated impl soname releases

    duplicated=$(awk '{ print $1, $2 }' <<< "${rows}" | sort | uniq -d)
    [ -n "${duplicated}" ] || return 0

    while read -r impl soname; do
        releases=$(awk -v impl="${impl}" -v soname="${soname}" \
            '$1 == impl && $2 == soname { printf "%s ", $3 }' <<< "${rows}")
        fail "[${impl}] ${soname} is answered by more than one release here (${releases%% }) - which one a binary loads is not this image's to say"
    done <<< "${duplicated}"

    return 1
}

# Version ordering, which both currencies answer to: 22.1.8 against 22.1.9, and
# GLIBCXX_3.4.35 against GLIBCXX_3.4.32, where the shared prefix sorts out of the way.
at_least(){
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

do_record(){
    local file="$1"
    local rows
    rows=$(current_rows)

    [ -n "${rows}" ] \
      || die "no C++ standard library found to record - ${stdlibs_script} reported nothing"

    check_unambiguous "${rows}" || return

    mkdir -p -- "$(dirname -- "${file}")"
    printf '%s\n' "${rows}" > "${file}" \
      || die "cannot write [${file}]"

    echo "[${this_script_name}] recorded $(wc -l < "${file}") standard librar(y/ies) into [${file}]:"
    sed 's/^/  /' "${file}"
}

# Each recorded SONAME must still be here, and be at least as capable as the one that was recorded.
#
#   - libstdc++ is compared with >= because GNU symbol versions are backward compatible by construction:
#     a library whose greatest GLIBCXX_ is above the recorded one still defines every symbol below it.
#     Same comparison the `GLIBCXX_x.y.z not found` error asks for - scripts/checks/README.md works one by hand.
#
#   - libc++ is compared for equality: it has no symbol versions, so there is no ordering to be lenient with.
#     Both stages resolve one package from one repository, so a difference is layer-cache skew rather than an upgrade.
do_verify(){
    local file="$1"

    [ -r "${file}" ] \
      || die "cannot read the recorded expectation [${file}] - was ${this_script_name} record run in the stage that compiled?"

    local rows
    rows=$(current_rows)
    [ -n "${rows}" ] \
      || die "no C++ standard library found in this image - ${stdlibs_script} reported nothing"

    check_unambiguous "${rows}" || return

    local impl soname version abi
    local here found_version found_abi
    while read -r impl soname version abi; do
        [ -n "${impl}" ] || continue

        here=$(awk -v impl="${impl}" -v soname="${soname}" \
            '$1 == impl && $2 == soname { print $3, $4; exit }' <<< "${rows}")
        if [ -z "${here}" ]; then
            fail "[${impl}] ${soname} was recorded but this image has no such library - it cannot run what was built against it"
            continue
        fi
        # NOTE: `read` leaves its variables untouched when it is fed nothing, which is what the
        # guard above prevents: a library missing here would be compared against the previous row.
        read -r found_version found_abi <<< "${here}"

        if [ "${found_version}" != "${version}" ]; then
            fail "[${impl}] ${soname} is ${found_version} here, ${version} where the binaries were built"
        else
            pass "[${impl}] ${soname} ${found_version}"
        fi

        if [ "${impl}" = 'libstdc++' ]; then
            if at_least "${found_abi}" "${abi}"; then
                pass "[${impl}] ${soname} reaches ${found_abi}, the binaries need up to ${abi}"
            else
                fail "[${impl}] ${soname} stops at ${found_abi}, the binaries need up to ${abi}"
            fi
        elif [ "${found_abi}" != "${abi}" ]; then
            fail "[${impl}] ${soname} exposes ${found_abi}, the binaries were built against ${abi}"
        else
            pass "[${impl}] ${soname} exposes ${found_abi}"
        fi
    done < "${file}"
}

mode="${1:-}"
file="${2:-}"

[ -n "${mode}" ] && [ -n "${file}" ] \
  || die "usage: ${this_script_name} <record|verify> <file>"

[ -r "${stdlibs_script}" ] \
  || die "cannot find cxx-stdlibs.sh one level above scripts/checks/details"

case "${mode}" in
    record ) do_record "${file}" ;;
    verify ) do_verify "${file}" ;;
    * )      die "unknown mode [${mode}] - expected one of: record, verify" ;;
esac

[ "${failures}" -eq 0 ] \
  || die "${failures} parity check(s) failed against [${file}]"

echo "[${this_script_name}] ${mode}: done"
exit 0
