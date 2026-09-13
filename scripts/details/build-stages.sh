#!/usr/bin/env bash
#
# This file is part of https://github.com/GuillaumeDua/cpp-toolchain
# License: see https://github.com/GuillaumeDua/cpp-toolchain/blob/main/LICENSE
#
# Build a list of Dockerfile stages, one buildx invocation each, on the builder already set up by the caller.
#
# The single driver for both workflows: docker-build.yml builds without pushing, docker-publish.yml
# validates and then builds with tags. They differ in flags, not in how a stage is built, so the buildx
# flags and the cache scope table below are defined here and nowhere else.
#
# Runs from the repository root - the build context is `.` and the Dockerfile path is relative to it.
#
# Usage:
#   build-stages.sh --variant <normal|cross> --cache <read|write|none> [--output cacheonly] STAGE...
#   build-stages.sh --variant <normal|cross> --cache <read|write|none> \
#                   --push --tags "<tag> <tag>" --metadata-dir <dir> STAGE...
#
#   --variant   normal builds the lean image; cross adds the cross-compilation toolchains.
#               It also decides the tag infix and the metadata file suffix, so a caller cannot pair them wrongly.
#   --cache     read exports nothing, write also exports the scope this variant/stage pair owns,
#               none passes no cache flags at all.
#   --output    cacheonly solves the stage for its exit status without producing an image.
#   --push      tag for every registry and push. Requires --tags and --metadata-dir.

set -euo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cross-arch target triplets. `common` is an alias resolved by scripts/install/binutils.sh,
# which is where the triplets are listed.
readonly CROSS_TARGETS='common'

# Layer cache, keyed <variant>:<stage> and valued by the scope that build exports.
#   One scope per exporting build - a second export to a scope replaces its index instead of merging into it,
#   "leaving only the final cache" (https://docs.docker.com/build/cache/backends/gha/).
#   Scopes are cheap: blobs are keyed by digest and only the index is scoped, so what the scopes share is stored once.
#   These three carry every layer a pull request builds - the runtime -> build -> static-analysis -> dev chain,
#   documentation's branch off build, and the cross binutils tail.
declare -A CACHE_EXPORTS=(
    ['normal:dev']=cpp-toolchain-dev
    ['normal:documentation']=cpp-toolchain-documentation
    ['cross:build']=cpp-toolchain-build-cross
)

usage() {
    sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
    echo "::error::build-stages.sh: $*" >&2
    exit 2
}

variant=''
cache=''
output=''
push='no'
tags=''
metadata_dir=''
stages=()

while [ $# -gt 0 ]; do
    case "$1" in
        --variant)      variant="${2:-}"; shift 2 ;;
        --cache)        cache="${2:-}"; shift 2 ;;
        --output)       output="${2:-}"; shift 2 ;;
        --tags)         tags="${2:-}"; shift 2 ;;
        --metadata-dir) metadata_dir="${2:-}"; shift 2 ;;
        --push)         push='yes'; shift ;;
        -h|--help)      usage; exit 0 ;;
        --*)            die "unknown option: $1" ;;
        *)              stages+=("$1"); shift ;;
    esac
done

case "${variant}" in
    normal) targets='';                 infix='';        metadata_suffix='' ;;
    cross)  targets="${CROSS_TARGETS}"; infix='cross-';  metadata_suffix='-cross' ;;
    *)      die "--variant must be normal or cross, got '${variant}'" ;;
esac

case "${cache}" in
    read|write|none) ;;
    *) die "--cache must be read, write or none, got '${cache}'" ;;
esac

case "${output}" in
    ''|cacheonly) ;;
    *) die "--output only accepts cacheonly, got '${output}'" ;;
esac

[ "${#stages[@]}" -gt 0 ] || die "no stage given"

if [ "${push}" = 'yes' ]; then
    [ -n "${tags}" ]         || die "--push needs --tags"
    [ -n "${metadata_dir}" ] || die "--push needs --metadata-dir"
    [ -z "${output}" ]       || die "--push and --output are mutually exclusive"
fi

cache_from=()
if [ "${cache}" != 'none' ]; then
    for scope in "${CACHE_EXPORTS[@]}"; do
        cache_from+=(--cache-from "type=gha,scope=${scope}")
    done
fi

registries=()
if [ "${push}" = 'yes' ]; then
    read -r -a registries <<< "$(python3 "${HERE}/check-release-file.py" --print-registries)"
    mkdir -p "${metadata_dir}"
fi

for stage in "${stages[@]}"; do
    build_args=(
        --file Dockerfile
        --target "${stage}"
        --build-arg "BINUTILS_TARGETS=${targets}"
    )
    build_args+=("${cache_from[@]}")

    if [ "${cache}" = 'write' ]; then
        scope="${CACHE_EXPORTS["${variant}:${stage}"]:-}"
        if [ -n "${scope}" ]; then
            build_args+=(--cache-to "type=gha,mode=max,scope=${scope}")
        fi
    fi

    if [ "${push}" = 'yes' ]; then
        for image in "${registries[@]}"; do
            for tag in ${tags}; do
                build_args+=(--tag "${image}:${stage}-${infix}${tag}")
                # `dev` is what `docker build` produces without --target, so it also answers to the unprefixed tag.
                if [ "${stage}" = 'dev' ]; then
                    build_args+=(--tag "${image}:${infix}${tag}")
                fi
            done
        done
        build_args+=(
            --provenance=false
            --sbom=false
            --metadata-file "${metadata_dir}/${stage}${metadata_suffix}.json"
            --push
        )
        label='build+push'
    elif [ "${output}" = 'cacheonly' ]; then
        build_args+=(--output type=cacheonly)
        label='solve'
    else
        label='build'
    fi

    echo "::group::${label} cpp-toolchain:${stage} [variant=${variant}]"
    docker buildx build "${build_args[@]}" .
    echo "::endgroup::"
done
