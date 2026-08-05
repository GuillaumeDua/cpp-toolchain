#!/usr/bin/env bash
# The one test that needs two images: compile in `build`, execute in `runtime`.
#
# This is the sole reason the runtime stage exists - it carries libc6/libgcc-s1/libstdc++6 from the
# same PPA the toolchain comes from, so a binary produced by `build` can ship in a much smaller image.
#
# Whether that actually holds depends on the PPA libstdc++ surviving both the --auto-remove
# purge and the snapshot dist-upgrade downgrade dance in the Dockerfile, and nothing has ever checked it.
# The repository's own notes flag it as never verified.
#
# Because it spans two images it cannot live in the per-stage loop: it runs once,
# after both are available, with the artifact handed between them through a directory on the host.
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
# No -static here, and none of its narrower spellings either:
# the artifact has to resolve libstdc++ and libgcc_s against the runtime image at load time.
# A self-contained binary would run there whatever that image holds,
# so this test would keep passing without measuring anything.
# That comes from g++'s defaults rather than from anything this command asks for,
# which is why the dynamic section is asserted below rather than assumed.
# The sibling cross test links -static, for reasons of its own - see smoke/cross.sh.
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

# libstdc++, libgcc_s and libc are what the runtime stage carries,
# and so exactly what the artifact has to be left borrowing from it.
# readelf runs in `build` rather than on the host,
# because binutils comes with the toolchain and a runner is guaranteed nothing.
echo "::group::dynamic section"
needed=$(docker run --rm \
    --volume "${artifacts}:/opt/cpp-toolchain-out:ro" \
    "${build_image}" \
    readelf -d /opt/cpp-toolchain-out/runtime-abi 2>&1)
status=$?
echo "${needed}"
echo "::endgroup::"

if [[ ${status} -ne 0 ]]; then
    echo "FAIL: could not read the artifact's dynamic section"
    exit 1
fi

missing=()
for library in libstdc++.so libgcc_s.so libc.so; do
    grep -qF "Shared library: [${library}" <<< "${needed}" || missing+=("${library}")
done

if [[ ${#missing[@]} -ne 0 ]]; then
    echo "FAIL: the artifact does not link ${missing[*]} dynamically"
    echo "  -static, -static-libstdc++ or -static-libgcc in the compile step above does this"
    echo "  and the run below would then pass whatever ${runtime_image} contains"
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
