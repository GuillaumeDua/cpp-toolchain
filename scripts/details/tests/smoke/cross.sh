#!/usr/bin/env bash
# Cross-compile the C++23 payload for every requested target, statically linked.
#
# Runs inside a -cross image (the caller bind-mounts the tests directory and an output directory),
# and the caller then executes the artifacts under qemu-<arch>-static on the runner.
#
# Static linking is not incidental.
#   The target sysroot lives inside this image, so a dynamically linked artifact cannot run anywhere else;
#   and qemu-user-static is not in the image and should not be added just to test it.
#   Linking statically is what lets the artifact leave the container.
#
# The target list is passed in rather than derived here: check-release-file.py owns it
# (--print-cross-targets), so the build loop, the verifier and this script cannot drift apart.
#
# Usage, from inside the image:
#   bash cross.sh <output-dir> <triplet>...

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source="${here}/cxx23.cpp"

out_dir="${1:?usage: cross.sh <output-dir> <triplet>...}"
shift
targets=("$@")
[[ ${#targets[@]} -eq 0 ]] && { echo "no targets given"; exit 2; }

mkdir -p "${out_dir}"

# Debian package names cannot contain underscores, so `g++-x86-64-linux-gnu` installs `/usr/bin/x86_64-linux-gnu-g++`.
# Normalising both spellings to hyphens means the lookup never has to know which side of that rename it is on;
# and only one of the four published triplets is affected,
# which is exactly how a hand-written mapping would survive review while being wrong.
normalise() { echo "${1//_/-}"; }

declare -A driver_of=()
shopt -s nullglob
for path in /usr/bin/*-g++; do
    name=$(basename -- "${path}")
    driver_of["$(normalise "${name%-g++}")"]="${name}"
done
shopt -u nullglob

failed=0

for target in "${targets[@]}"; do
    echo "::group::cross ${target}"
    key=$(normalise "${target}")
    driver="${driver_of[${key}]:-}"

    if [[ -z "${driver}" ]]; then
        # binutils.sh installs each target best-effort and its skip log is a no-op under the
        # Dockerfile's --silent=yes, so this is the failure that currently builds green and silent.
        echo "FAIL ${target}: no cross g++ installed (looked for ${key}-g++)"
        failed=1
        echo "::endgroup::"
        continue
    fi

    echo "${target}: ${driver} - $("${driver}" --version 2>&1 | head -n 1)"
    artifact="${out_dir}/cxx23-${target}"

    if ! "${driver}" -std=c++23 -Wall -Wextra -Werror -static "${source}" -o "${artifact}"; then
        echo "FAIL ${target}: cross-compilation failed"
        failed=1
        echo "::endgroup::"
        continue
    fi

    if ! file "${artifact}" 2>/dev/null; then
        echo "(file(1) not installed - skipping the artifact description)"
    fi
    echo "PASS ${target}: built $(basename -- "${artifact}")"
    echo "::endgroup::"
done

[[ ${failed} -eq 0 ]] && echo "cross build passed (${targets[*]})" || echo "cross build FAILED"
exit "${failed}"
