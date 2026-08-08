#!/bin/bash
set -uo pipefail

# See docs/IMAGES_VALIDATION.md

this_script_name=$(basename "$0")
this_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# One level up: the standards probe is standalone, it is not a detail of this gate.
standards_script="${this_script_dir}/../check-compiler-supported-cxx-standards.sh"

# The installers own how their packages are named, so they answer what is installed.
install_scripts_dir="${this_script_dir}/../../install"

warning_flags=('-Wall' '-Wextra')

payload_source=''
failures=0

die()  { echo "[${this_script_name}] error: $*" >&2; exit 1; }
fail() { echo "[${this_script_name}] FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "[${this_script_name}] ok:   $*"; }

# Binaries are reported as <directory>/<name>, so the libstdc++ and libc++ passes stay distinct.
label(){
    echo "$(basename -- "$(dirname -- "$1")")/$(basename -- "$1")"
}

# The payload sits next to this script inside an image, and under test/ in a checkout.
resolve_payload_source(){
    local candidate
    for candidate in \
        "${this_script_dir}/cxx_runtime.cpp" \
        "${this_script_dir}/../../../test/cxx_runtime.cpp"
    do
        if [ -f "${candidate}" ]; then
            echo "${candidate}"
            return 0
        fi
    done
    die "cannot find cxx_runtime.cpp next to ${this_script_name} nor under test/"
}

# Draft and final spellings of one standard share a __cplusplus value,
# so only the first spelling of each value is kept.
# Invoked through bash rather than directly: the repository does not carry an executable bit.
standards_for(){
    bash "${standards_script}" --stable "$1" 2>/dev/null \
      | awk '{ split($0, fields, "__cplusplus="); if (!seen[fields[2]]++) print $1 }'
}

compile_one(){
    local cxx="$1"
    local standard="$2"
    local output="$3"
    shift 3

    local diagnostics
    diagnostics=$(mktemp)

    mkdir -p -- "$(dirname -- "${output}")"
    if "${cxx}" -std="${standard}" "${warning_flags[@]}" "$@" "${payload_source}" -o "${output}" 2>"${diagnostics}"; then
        pass "compiled [$(label "${output}")]"
    else
        fail "[${cxx}] failed to compile at -std=${standard}: $(tr '\n' ' ' <"${diagnostics}")"
    fi
    rm -f -- "${diagnostics}"
}

compile_for_compiler(){
    local cxx="$1"
    local destination="$2"
    shift 2

    if ! command -v "${cxx}" >/dev/null 2>&1; then
        fail "[${cxx}] is expected in this image but is not on PATH"
        return
    fi

    local standards
    mapfile -t standards < <(standards_for "${cxx}")
    if [ "${#standards[@]}" -eq 0 ]; then
        fail "[${cxx}] exposes no usable C++ standard"
        return
    fi

    local standard
    for standard in "${standards[@]}"; do
        compile_one "${cxx}" "${standard}" "${destination}/${cxx}-${standard}" "$@"
    done
}

# Debian names the cross packages with x86-64 and the cross binaries with x86_64.
cross_compiler_for(){
    echo "${1/x86-64/x86_64}-g++"
}

do_compile(){
    local root="$1"

    [ -d "${install_scripts_dir}" ] \
      || die "cannot find scripts/install two levels above scripts/checks/details"

    local gcc_majors
    local clang_majors
    mapfile -t gcc_majors   < <(bash "${install_scripts_dir}/gcc.sh"  --list-installed)
    mapfile -t clang_majors < <(bash "${install_scripts_dir}/llvm.sh" --list-installed)

    [ $(( ${#gcc_majors[@]} + ${#clang_majors[@]} )) -gt 0 ] \
      || die "no C++ compiler is installed in this image"

    local major
    for major in "${gcc_majors[@]}"; do
        compile_for_compiler "g++-${major}" "${root}/bin"
    done
    for major in "${clang_majors[@]}"; do
        compile_for_compiler "clang++-${major}" "${root}/bin"
        compile_for_compiler "clang++-${major}" "${root}/libcxx" '-stdlib=libc++'
    done

    # The build argument may name an alias such as `common`, so binutils.sh resolves it.
    # Still the build argument rather than what is installed: that is what turns a silently
    # skipped target into a missing compiler here.
    local targets
    mapfile -t targets < <(bash "${install_scripts_dir}/binutils.sh" --list-targets --targets="${BINUTILS_TARGETS:-}")
    local target
    for target in "${targets[@]}"; do
        compile_for_compiler "$(cross_compiler_for "${target}")" "${root}/cross"
    done
}

list_binaries(){
    find "$1" -type f -perm -u+x 2>/dev/null | sort
}

# A statically linked payload would resolve nothing at run time,
# which would make the runtime check pass without proving anything.
do_inspect(){
    local binaries
    mapfile -t binaries < <(list_binaries "$1")
    [ "${#binaries[@]}" -gt 0 ] || die "no binary found under [$1]"

    local binary
    for binary in "${binaries[@]}"; do
        if readelf -d "${binary}" 2>/dev/null | grep -qE 'NEEDED.*lib(stdc\+\+|c\+\+)\.so'; then
            pass "[$(label "${binary}")] declares a C++ runtime as NEEDED"
        else
            fail "[$(label "${binary}")] has no C++ runtime in NEEDED - linked statically?"
        fi
    done
}

do_run(){
    local binaries
    mapfile -t binaries < <(list_binaries "$1")
    [ "${#binaries[@]}" -gt 0 ] || die "no binary found under [$1]"

    local binary
    for binary in "${binaries[@]}"; do
        local name
        name=$(label "${binary}")

        local unresolved
        unresolved=$(ldd "${binary}" 2>/dev/null | grep 'not found')
        if [ -n "${unresolved}" ]; then
            fail "[${name}] has unresolved libraries: $(tr '\n' ' ' <<< "${unresolved}")"
            continue
        fi

        local output
        if ! output=$("${binary}" 2>&1); then
            fail "[${name}] exited non-zero: ${output}"
            continue
        fi
        if ! grep -q '^stdlib=' <<< "${output}"; then
            fail "[${name}] produced unexpected output: ${output}"
            continue
        fi
        pass "[${name}] ${output}"
    done
}

mode="${1:-}"
root="${2:-}"

[ -n "${mode}" ] && [ -n "${root}" ] \
  || die "usage: ${this_script_name} <compile|inspect|run> <directory>"

case "${mode}" in
    compile )
        payload_source=$(resolve_payload_source)
        do_compile "${root}"
        ;;
    inspect )
        do_inspect "${root}"
        ;;
    run )
        do_run "${root}"
        ;;
    * )
        die "unknown mode [${mode}] - expected one of: compile, inspect, run"
        ;;
esac

[ "${failures}" -eq 0 ] \
  || die "${failures} ${mode} check(s) failed under [${root}]"

echo "[${this_script_name}] ${mode}: all checks passed under [${root}]"
exit 0
