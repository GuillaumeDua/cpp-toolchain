# =============================================================================================
# This file is part of https://github.com/GuillaumeDua/cpp-toolchain
# License: see https://github.com/GuillaumeDua/cpp-toolchain/blob/main/LICENSE
#
# One copy of each helper the scripts under scripts/ share.
#
# The public scripts - scripts/install/*.sh, and the three that scripts/checks/README.md tells you to
# wget - have to work as a single file on a machine that has never seen this repository, so they
# cannot source this one. Each carries its own copy of the helpers it uses.
# The internal scripts already read their siblings by relative path, so they source this file instead.
#
# compose-standalone.py, beside this file, builds them:
#     python3 scripts/details/compose-standalone.py scripts/install/gcc.sh > gcc.sh
# It inlines only the helpers a script calls. The build gate composes all of them and runs each one
# in an empty directory, and each release attaches the results.
#
# Two things every caller defines itself, because one value cannot serve all of them:
#
#   retry_backoff_seconds   how long run_with_retries waits between attempts. It has to outlast the
#                           throttling window of the host that script downloads from, and those
#                           differ. Deliberately left undefined here: under `set -u`, a script that
#                           forgets it stops at the first retry instead of retrying with no wait.
#   error()                 what to_boolean calls when handed something that is not a boolean.
#                           Each script composes its own error_diagnosis, and its clean where it
#                           has one.
#
# Sourced, never executed, hence no shebang.
# =============================================================================================

# A caller that sets one of these before sourcing keeps its value, and an option parser below the
# source line overwrites arg_silent the same way.
: "${this_script_name:=$(basename "$0")}"
: "${arg_silent:=1}"
: "${max_attempts:=3}"

# dpkg is the authority inside the images, and absent outside them - package_of answers [-] there.
has_dpkg=0
command -v dpkg-query >/dev/null 2>&1 && has_dpkg=1

# For the gate scripts, which tally rather than stop at the first problem.
failures=0

die() { echo "[${this_script_name}] error: $*" >&2; exit 1; }

fail() { echo "[${this_script_name}] FAIL: $*" >&2; failures=$((failures + 1)); }

pass() { echo "[${this_script_name}] ok:   $*"; }

warning(){
    echo -e "[${this_script_name}]: $@" >> /dev/stderr
}

log(){
    if [[ "${arg_silent}" == 1 ]]; then
        return 0;
    fi
    echo -e "[${this_script_name}]: $@"
    return 0
}

to_boolean(){
    if [[ $# != 1 ]]; then
        error "$0: missing argument"
    fi
    case "$1" in
        [Yy]|[Yy][Ee][Ss]|1|[Tt][Rr][Uu][Ee]) echo 1;;
        [Nn]|[Nn][Oo]|0|[Ff][Aa][Ll][Ss][Ee]) echo 0;;
        *)
            error "to_boolean: invalid conversion from [$1] to boolean"
            ;;
    esac
}

# Runs a command quietly, replaying its output only if it fails.
run(){
    local what="$1"; shift
    local output streamed=0 status=0

    output=$(mktemp)
    if [[ "${arg_silent}" == 0 ]]; then
        # stderr, because stdout carries the result to the caller.
        streamed=1
        "$@" 2>&1 | tee "${output}" >&2
        status=${PIPESTATUS[0]}
    else
        "$@" > "${output}" 2>&1 || status=$?
    fi

    if [ "${status}" -eq 0 ]; then
        rm -f "${output}"
        return 0
    fi

    {
        echo -e "[${this_script_name}]: ${what} failed - exit status [${status}]"
        echo -e "[${this_script_name}]: command: [$*]"
        if [ "${streamed}" -eq 0 ]; then
            echo -e "[${this_script_name}]: --- output ---"
            cat "${output}"
            echo -e "[${this_script_name}]: --- end of output ---"
        fi
    } >> /dev/stderr
    rm -f "${output}"
    return "${status}"
}

# A third-party host can refuse a request transiently - that should not sink a whole image build.
# Every step retried here is idempotent, and only the last attempt reports.
run_with_retries(){
    local attempts="$1" what="$2"; shift 2
    local attempt=1

    while [ "${attempt}" -lt "${attempts}" ]; do
        "$@" > /dev/null 2>&1 && return 0
        warning "${what} failed - retrying in $(( attempt * retry_backoff_seconds ))s (attempt $(( attempt + 1 ))/${attempts})"
        sleep $(( attempt * retry_backoff_seconds ))
        attempt=$(( attempt + 1 ))
    done
    run "${what}" "$@"
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
# and only the release in the middle is what a developer calls the version.
version_of_package(){
    [ "$1" != '-' ] || { printf '%s' '-'; return; }

    local version
    version=$(dpkg-query -W -f='${Version}' "$1" 2>/dev/null)
    version="${version#*:}"
    version="${version%%[-~]*}"
    printf '%s' "${version:--}"
}
