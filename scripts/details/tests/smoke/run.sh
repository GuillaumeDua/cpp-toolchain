#!/usr/bin/env bash
# Compile and run the C++23 payload with every default compiler in the image.
#
# Runs inside the image under test (the caller bind-mounts the tests directory),
# so it may only use what the stage ships.
# It holds no version knowledge: which compilers are installed and at what version is check-image.sh's question,
# and this one only asks whether they work.
#
# Reports every compiler before failing, rather than stopping at the first.
# The predecessor of this script stopped at g++, so a broken clang++ was invisible whenever both were broken;
# and "both are broken" is the likely shape of an upstream breakage, not the unlikely one.
#
# Usage, from inside the image:
#   bash run.sh [<compiler>...]      # default: g++ clang++

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source="${here}/cxx23.cpp"

tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

compilers=("$@")
[[ ${#compilers[@]} -eq 0 ]] && compilers=(g++ clang++)

failed=0

for cxx in "${compilers[@]}"; do
    echo "::group::smoke ${cxx}"

    if ! command -v -- "${cxx}" >/dev/null 2>&1; then
        echo "FAIL ${cxx}: not installed"
        failed=1
        echo "::endgroup::"
        continue
    fi

    echo "${cxx}: $("${cxx}" --version 2>&1 | head -n 1)"
    binary="${tmp}/cxx23-${cxx}"

    # -Werror on purpose: a new warning from a toolchain bump is a change in what the image gives its users,s
    # and the point of this suite is to see those before they are published.
    if ! "${cxx}" -std=c++23 -Wall -Wextra -Werror "${source}" -o "${binary}"; then
        echo "FAIL ${cxx}: compilation failed"
        failed=1
        echo "::endgroup::"
        continue
    fi

    output=$("${binary}" 2>&1)
    status=$?
    echo "${output}"

    if [[ ${status} -ne 0 ]]; then
        echo "FAIL ${cxx}: the binary exited ${status}"
        failed=1
    elif [[ "${output}" != *cxx23-ok* ]]; then
        # Exit status alone would accept a binary that links, runs and silently does nothing.
        echo "FAIL ${cxx}: expected the cxx23-ok marker in the output"
        failed=1
    else
        echo "PASS ${cxx}"
    fi

    echo "::endgroup::"
done

[[ ${failed} -eq 0 ]] && echo "smoke test passed (${compilers[*]})" || echo "smoke test FAILED"
exit "${failed}"
