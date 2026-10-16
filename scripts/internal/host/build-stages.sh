#!/usr/bin/env bash
#
# This file is part of https://github.com/GuillaumeDua/cpp-toolchain
# License: see https://github.com/GuillaumeDua/cpp-toolchain/blob/main/LICENSE
#
# Build a list of Dockerfile stages, one buildx invocation each, on the builder already set up by the caller.
#
# The single driver for both workflows: docker-build.yml builds without pushing, docker-publish.yml
# validates and then builds with tags. They differ in flags, not in how a stage is built, so the buildx
# flags and the cache table below are defined here and nowhere else.
#
# Runs from the repository root - the build context is `.` and the Dockerfile path is relative to it.
#
# Usage:
#   build-stages.sh --variant <normal|cross> --cache <read|write|none> [--output cacheonly] STAGE...
#   build-stages.sh --variant <normal|cross> --cache <read|write|none> \
#                   --push --tags "<tag> <tag>" --metadata-dir <dir> STAGE...
#   build-stages.sh --variant <normal|cross> --metadata-dir <dir> --print-digest STAGE
#
#   --variant       normal builds the lean image; cross adds the cross-compilation toolchains.
#                   It also decides the tag infix and the metadata file suffix, so a caller cannot pair them wrongly.
#   --cache         read imports every cache tag, write also exports the one this variant/stage pair owns,
#                   none passes no cache flags at all.
#   --output        cacheonly solves the stage for its exit status without producing an image.
#   --push          tags for every registry and pushes. Requires --tags and --metadata-dir.
#   --print-digest  print the digest --push recorded for one stage, and build nothing. Reads the file
#                   --variant and --metadata-dir name between them, so no caller spells that name.

set -euo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cross-arch target triplets. `common` is an alias resolved by scripts/install/binutils.sh,
# which is where the triplets are listed.
readonly CROSS_TARGETS='common'

# Layer cache, keyed <variant>:<stage> and valued by the tag that build exports.
#   The tags sit on the GHCR repository the images publish to: a pull request imports with no credentials,
#   and GHCR creates a new package private.
#   One tag per exporting build - a second export to a tag replaces the manifest there instead of merging into it.
#   These three carry every layer a pull request builds - the runtime -> build -> static-analysis -> dev chain,
#   documentation's branch off build, and the cross binutils tail.
declare -A CACHE_EXPORTS=(
    ['normal:dev']=buildcache-dev
    ['normal:documentation']=buildcache-documentation
    ['cross:build']=buildcache-build-cross
)

# The registry backend's export parameters (https://docs.docker.com/build/cache/backends/registry/):
#   ignore-error, because the export is the last thing a build does: without it a registry hiccup fails a
#     build whose every stage succeeded, while the tag already there stays importable.
#   image-manifest, because docker-publish.yml sweeps every untagged version of this package: under an index
#     the cache manifests are untagged children, where a single manifest is the tagged version itself.
#     It applies to OCI media types only, hence the pair.
readonly CACHE_EXPORT_FLAGS='type=registry,mode=max,ignore-error=true,oci-mediatypes=true,image-manifest=true'

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
print_digest='no'
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
        --print-digest) print_digest='yes'; shift ;;
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

# The metadata file is read here rather than by the caller, because the case above is the only place
# `metadata_suffix` is spelled. A caller that built the name itself could look for a file no build wrote.
if [ "${print_digest}" = 'yes' ]; then
    [ -n "${metadata_dir}" ]  || die "--print-digest needs --metadata-dir"
    [ "${#stages[@]}" -eq 1 ] || die "--print-digest takes one stage, got ${#stages[@]}"
    metadata_file="${metadata_dir}/${stages[0]}${metadata_suffix}.json"
    # Not a soft failure: an empty digest would promote a record naming an image that does not exist.
    [ -r "${metadata_file}" ] || die "no build metadata at ${metadata_file}"
    python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["containerimage.digest"])' \
        "${metadata_file}"
    exit 0
fi

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
    # The registry name belongs to check_release_file.py, cache tags included.
    cache_image="$(python3 "${HERE}/check_release_file.py" --print-registries ghcr)"
    for cache_tag in "${CACHE_EXPORTS[@]}"; do
        cache_from+=(--cache-from "type=registry,ref=${cache_image}:${cache_tag}")
    done
fi

registries=()
if [ "${push}" = 'yes' ]; then
    read -r -a registries <<< "$(python3 "${HERE}/check_release_file.py" --print-registries)"
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
        cache_tag="${CACHE_EXPORTS["${variant}:${stage}"]:-}"
        if [ -n "${cache_tag}" ]; then
            build_args+=(--cache-to "${CACHE_EXPORT_FLAGS},ref=${cache_image}:${cache_tag}")
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
