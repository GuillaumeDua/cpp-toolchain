#!/usr/bin/env bash
# Report facts about the image this runs inside - and assert nothing.
#
# Every assertion lives on the host, in verify-image.py, where the Dockerfile's pins are readable.
# This half deliberately holds no version knowledge at all:
# there is no field here to write a version into, so the single-source-of-truth rule is structural
# rather than a convention someone has to remember.
#   `grep -E '[0-9]+\.[0-9]+' probe.sh` returning nothing is a test in verify-image.py.
#
# Runs inside every published stage, so it may only use what the leanest one ships:
# bash, coreutils, ldconfig, readlink, dpkg-query. No python3, no jq - `runtime` has neither.
#
# Output is one `key<TAB>value` line per requested key, in the order requested.
# A missing tool reports `absent` rather than failing:
# the negative expectations ("runtime has no compiler", "build has no unversioned clang-tidy")
# need absence reported as data, and silence has to stay distinguishable from a key that was never asked for.
#
# Usage - keys are given as arguments, so the emitted set is stage-scoped:
#   bash probe.sh cmd:cmake path:/opt/vcpkg/vcpkg alt:clang-tidy glob:'/usr/bin/g++-*'

# Note `-e` is absent on purpose: probing a tool that is not installed must record `absent` and carry
# on, and almost every handler below is expected to fail somewhere in a lean stage.
set -uo pipefail

ABSENT='absent'

emit() { printf '%s\t%s\n' "$1" "$2"; }

# First line of `<tool> --version`, squashed to one line.
# Some tools print their version to stderr (and some, to both), so stderr is folded in.
version_of() {
    local tool="$1" out
    command -v -- "${tool}" >/dev/null 2>&1 || { echo "${ABSENT}"; return; }
    out=$("${tool}" --version 2>&1 | head -n 1 | tr -d '\r\t')
    [[ -n "${out}" ]] && echo "${out}" || echo "${ABSENT}"
}

# Where an unversioned command actually points, resolved through symlinks.
# This is what makes the update-alternatives boundary between `build` and `static-analysis` visible:
# both physically contain the clang-tidy-N package, and only the registration differs.
target_of() {
    local tool="$1" path
    path=$(command -v -- "${tool}" 2>/dev/null) || { echo "${ABSENT}"; return; }
    readlink -f -- "${path}" 2>/dev/null || echo "${ABSENT}"
}

# Basenames matching a glob, space-separated and sorted.
# The enumerating key: `cmd:` and `alt:` are single-valued, and GCC and LLVM are not.
matches_of() {
    local pattern="$1" found=() entry
    shopt -s nullglob
    for entry in ${pattern}; do
        [[ -e "${entry}" ]] && found+=("$(basename -- "${entry}")")
    done
    shopt -u nullglob
    [[ ${#found[@]} -eq 0 ]] && { echo "${ABSENT}"; return; }
    printf '%s\n' "${found[@]}" | sort | tr '\n' ' ' | sed 's/ $//'
}

# Value of `<key>=` in a shell-style file (/etc/os-release), unquoted.
field_of() {
    local file="$1" key="$2" line
    [[ -r "${file}" ]] || { echo "${ABSENT}"; return; }
    line=$(grep -m1 -E "^${key}=" -- "${file}" 2>/dev/null) || { echo "${ABSENT}"; return; }
    line="${line#*=}"
    line="${line%\"}"
    line="${line#\"}"
    [[ -n "${line}" ]] && echo "${line}" || echo "${ABSENT}"
}

# The apt archive snapshot the sources were rewritten to.
# Proves the sed in the Dockerfile's realignment block actually applied:
# an image whose sources still point at archive.ubuntu.com is not reproducible, however green it builds.
snapshot_of() {
    local found
    found=$(grep -rhoE 'snapshot\.ubuntu\.com/ubuntu/[0-9TZ]+' \
                /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null \
            | head -n 1 | sed 's#.*/##')
    [[ -n "${found}" ]] && echo "${found}" || echo "${ABSENT}"
}

# Installed package version, straight from the dpkg status database.
# Not `apt-cache policy`: every apt block in the Dockerfile ends with `rm -rf /var/lib/apt/lists/*`,
# so no published image has package lists to query. The status database is local and always present.
package_of() {
    local pkg="$1" out
    out=$(dpkg-query -W -f='${Version}' -- "$1" 2>/dev/null) || { echo "${ABSENT}"; return; }
    [[ -n "${out}" ]] && echo "${out}" || echo "${ABSENT}"
}

for key in "$@"; do
    case "${key}" in
        cmd:*)   emit "${key}" "$(version_of "${key#cmd:}")" ;;
        alt:*)   emit "${key}" "$(target_of  "${key#alt:}")" ;;
        glob:*)  emit "${key}" "$(matches_of "${key#glob:}")" ;;
        dpkg:*)  emit "${key}" "$(package_of "${key#dpkg:}")" ;;
        path:*)
            target="${key#path:}"
            [[ -e "${target}" ]] && emit "${key}" present || emit "${key}" "${ABSENT}"
            ;;
        lib:*)
            soname="${key#lib:}"
            if ldconfig -p 2>/dev/null | grep -qF -- "${soname}"; then
                emit "${key}" present
            else
                emit "${key}" "${ABSENT}"
            fi
            ;;
        file:*)
            # `file:/etc/os-release:VERSION_ID` - the field name is after the last colon,
            # so a path containing colons still parses.
            rest="${key#file:}"
            emit "${key}" "$(field_of "${rest%:*}" "${rest##*:}")"
            ;;
        git:*)
            dir="${key#git:}"
            if [[ -d "${dir}/.git" ]] && command -v git >/dev/null 2>&1; then
                emit "${key}" "$(git -C "${dir}" rev-parse HEAD 2>/dev/null || echo "${ABSENT}")"
            else
                emit "${key}" "${ABSENT}"
            fi
            ;;
        grep:*)
            # `grep:<file>:<fixed-string>` - presence of a literal line fragment,
            # for things with no command to interrogate (the powerlevel10k theme line in .zshrc).
            rest="${key#grep:}"
            haystack="${rest%:*}"
            needle="${rest##*:}"
            if [[ -r "${haystack}" ]] && grep -qF -- "${needle}" "${haystack}" 2>/dev/null; then
                emit "${key}" present
            else
                emit "${key}" "${ABSENT}"
            fi
            ;;
        apt-src) emit "${key}" "$(snapshot_of)" ;;
        *)
            # An unknown key is the host asking for something this probe cannot answer.
            # Reporting it rather than skipping keeps the host's "every requested key came back" check honest.
            emit "${key}" 'unsupported-key'
            ;;
    esac
done
