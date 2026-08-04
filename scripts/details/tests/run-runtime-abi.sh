#!/usr/bin/env bash
# The one test that needs two images: compile in `build`, execute in `runtime`.
#
# This is the sole reason the runtime stage exists - it carries libc6/libgcc-s1/libstdc++6 from the
# same PPA the toolchain comes from, so a binary produced by `build` can ship in a much smaller
# image. Whether that actually holds depends on the PPA libstdc++ surviving both the --auto-remove
# purge and the snapshot dist-upgrade downgrade dance in the Dockerfile, and nothing has ever
# checked it. The repository's own notes flag it as never verified.
#
# Because it spans two images it cannot live in the per-stage loop: it runs once, after both are
# available, with the artifact handed between them through a directory on the host.
#
# Usage, from the repository root:
#   bash scripts/details/tests/run-runtime-abi.sh <build-image> <runtime-image>

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

build_image="${1:?usage: run-runtime-abi.sh <build-image> <runtime-image>}"
runtime_image="${2:?usage: run-runtime-abi.sh <build-image> <runtime-image>}"

artifacts=$(mktemp -d)
trap 'rm -rf "${artifacts}"' EXIT

echo "::group::compile in ${build_image}"
# Dynamically linked on purpose: a static binary would prove nothing about the runtime image, which
# is the entire subject of this test.
docker run --rm \
    --volume "${here}:/opt/cpp-toolchain-tests:ro" \
    --volume "${artifacts}:/opt/cpp-toolchain-out" \
    "${build_image}" \
    bash -c 'g++ -std=c++23 -Wall -Wextra -Werror \
                 /opt/cpp-toolchain-tests/smoke/runtime-abi.cpp \
                 -o /opt/cpp-toolchain-out/runtime-abi' || {
    echo "FAIL: compilation in ${build_image} failed"
    echo "::endgroup::"
    exit 1
}
echo "::endgroup::"

if [[ ! -x "${artifacts}/runtime-abi" ]]; then
    echo "FAIL: no artifact was produced"
    exit 1
fi

echo "::group::execute in ${runtime_image}"
output=$(docker run --rm \
    --volume "${artifacts}:/opt/cpp-toolchain-out:ro" \
    "${runtime_image}" \
    /opt/cpp-toolchain-out/runtime-abi 2>&1)
status=$?
echo "${output}"
echo "::endgroup::"

if [[ ${status} -ne 0 ]]; then
    echo "FAIL: the artifact exited ${status} in ${runtime_image}"
    echo "  a libstdc++ or libgcc_s skew between the two stages is the usual cause"
    exit 1
fi

if [[ "${output}" != *runtime-abi-ok* ]]; then
    echo "FAIL: expected the runtime-abi-ok marker in the output"
    exit 1
fi

echo "runtime ABI test passed - ${build_image} output runs in ${runtime_image}"
