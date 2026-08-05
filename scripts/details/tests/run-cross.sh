#!/usr/bin/env bash
# Host side of the cross smoke test: build the artifacts inside the image, then run them here.
#
# The split exists because neither half can do both jobs. The cross toolchain and its target sysroot
# live inside the image; qemu-user-static lives on the runner and should not be added to a published
# image just to test it. So the image cross-compiles statically, and the runner executes.
#
# Foreign binaries run through binfmt_misc, which docker/setup-qemu-action registers with the `F`
# (fix binary) flag - that loads the interpreter at registration time, so a static foreign binary is
# directly executable on the host afterwards. Where that has not happened, this falls back to an
# explicit qemu-<arch>-static, and says so rather than silently skipping.
#
# Usage, from the repository root:
#   bash scripts/details/tests/run-cross.sh <image> [<triplet>...]

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
details=$(dirname -- "${here}")

image="${1:?usage: run-cross.sh <image> [<triplet>...]}"
shift
targets=("$@")
if [[ ${#targets[@]} -eq 0 ]]; then
    read -r -a targets <<< "$(python3 "${details}/check-release-file.py" --print-cross-targets)"
fi

artifacts=$(mktemp -d)
trap 'rm -rf "${artifacts}"' EXIT

echo "cross-building in ${image} for: ${targets[*]}"
docker run --rm \
    --volume "${here}:/opt/cpp-toolchain-tests:ro" \
    --volume "${artifacts}:/opt/cpp-toolchain-out" \
    "${image}" \
    bash /opt/cpp-toolchain-tests/smoke/cross.sh /opt/cpp-toolchain-out "${targets[@]}" || exit 1

# Triplet -> qemu architecture. Only the x86-64 spelling needs special handling:
# it is the host architecture, so its artifact runs natively and needs no interpreter at all.
qemu_arch_of() {
    case "$1" in
        x86-64-* | x86_64-*) echo native ;;
        *) echo "${1%%-*}" ;;
    esac
}

failed=0

for target in "${targets[@]}"; do
    echo "::group::run ${target}"
    artifact="${artifacts}/cxx23-${target}"

    if [[ ! -x "${artifact}" ]]; then
        echo "FAIL ${target}: no artifact was produced"
        failed=1
        echo "::endgroup::"
        continue
    fi

    arch=$(qemu_arch_of "${target}")
    if [[ "${arch}" == native ]]; then
        runner=()
    elif output=$("${artifact}" 2>&1) && [[ "${output}" == *cxx23-ok* ]]; then
        # binfmt_misc handled it transparently - nothing more to arrange.
        echo "PASS ${target} (binfmt): ${output}"
        echo "::endgroup::"
        continue
    elif command -v "qemu-${arch}-static" >/dev/null 2>&1; then
        runner=("qemu-${arch}-static")
    else
        echo "FAIL ${target}: not runnable - binfmt_misc did not handle it and qemu-${arch}-static is not installed"
        echo "  (docker/setup-qemu-action registers the binfmt handlers; on a bare host, install qemu-user-static)"
        failed=1
        echo "::endgroup::"
        continue
    fi

    output=$("${runner[@]}" "${artifact}" 2>&1)
    status=$?
    echo "${output}"

    if [[ ${status} -ne 0 ]]; then
        echo "FAIL ${target}: exited ${status}"
        failed=1
    elif [[ "${output}" != *cxx23-ok* ]]; then
        echo "FAIL ${target}: expected the cxx23-ok marker in the output"
        failed=1
    else
        echo "PASS ${target}"
    fi

    echo "::endgroup::"
done

[[ ${failed} -eq 0 ]] && echo "cross smoke test passed (${targets[*]})" || echo "cross smoke test FAILED"
exit "${failed}"
