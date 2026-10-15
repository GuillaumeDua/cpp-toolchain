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
#   build-stages.sh --variant <normal|cross> --cache <read|write|none> [--output cacheonly] [--retries N] STAGE...
#   build-stages.sh --variant <normal|cross> --cache <read|write|none> \
#                   --push --tags "<tag> <tag>" --metadata-dir <dir> STAGE...
#   build-stages.sh --variant <normal|cross> --metadata-dir <dir> --print-digest STAGE
#
#   --variant       normal builds the lean image; cross adds the cross-compilation toolchains.
#                   It also decides the tag infix and the metadata file suffix, so a caller cannot pair them wrongly.
#   --cache         read imports every scope, write also exports the one this variant/stage pair owns,
#                   none passes no cache flags at all.
#   --output        cacheonly solves the stage for its exit status without producing an image.
#   --retries       attempts per stage. Above 1, a build that failed on a transient fetch error is
#                   retried; any other failure stops on the first attempt. Default 1.
#   --push          tags for every registry and pushes. Requires --tags and --metadata-dir.
#   --print-digest  print the digest --push recorded for one stage, and build nothing. Reads the file
#                   --variant and --metadata-dir name between them, so no caller spells that name.

set -euo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cross-arch target triplets. `common` is an alias resolved by scripts/install/binutils.sh,
# which is where the triplets are listed.
readonly CROSS_TARGETS='common'

# A stage that failed is retried only when its log names a transient cause: every stage installs from a
# third-party host, and a refused or stalled request is not a broken tree.
#   Keyed on the cause rather than on an exit status, because buildx answers 1 to every solve failure,
#   and apt answers 100 to a 503 and to a package that does not exist alike.
#   A 404 is deliberately absent: a version that left the mirror is a real error, and a retry only
#   delays the report.
#   The server's status is matched, never its reason phrase: snapshot.ubuntu.com answers 503 from nginx
#   as "Service Unavailable" and from its load balancer as "No server is available to handle this request".
readonly TRANSIENT_FAILURE='(Err:[0-9]+|Failed to fetch).* 5[0-9][0-9]( |$)|Connection timed out|Connection failed|Could not resolve|Temporary failure resolving|429 Too Many Requests|TLS handshake timeout|i/o timeout|connection reset by peer'
readonly RETRY_PAUSE_SECONDS=30

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
retries=1
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
        --retries)      retries="${2:-}"; shift 2 ;;
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

case "${retries}" in
    ''|*[!0-9]*|0) die "--retries must be a positive integer, got '${retries}'" ;;
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
    read -r -a registries <<< "$(python3 "${HERE}/check_release_file.py" --print-registries)"
    mkdir -p "${metadata_dir}"
fi

# Classifying a failure means reading the build's own output, so it is captured when retrying.
# `tee` keeps it streaming meanwhile, as scripts/lib/shared.sh does for the same reason.
build_log=''
if [ "${retries}" -gt 1 ]; then
    build_log="$(mktemp)"
    trap 'rm -f "${build_log}"' EXIT
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

    attempt=1
    while true; do
        group="${label} cpp-toolchain:${stage} [variant=${variant}]"
        if [ "${retries}" -gt 1 ]; then
            group+=" - attempt ${attempt}/${retries}"
        fi
        echo "::group::${group}"

        # Nothing to classify with a single attempt, so the output is left alone: errexit reports the
        # failure, and buildx keeps its interactive progress for a local build.
        if [ "${retries}" -eq 1 ]; then
            docker buildx build "${build_args[@]}" .
            echo "::endgroup::"
            break
        fi

        status=0
        docker buildx build "${build_args[@]}" . 2>&1 | tee "${build_log}" >&2 || status=$?
        echo "::endgroup::"

        if [ "${status}" -eq 0 ]; then
            break
        fi

        if ! grep -qE "${TRANSIENT_FAILURE}" "${build_log}"; then
            exit "${status}"
        fi

        if [ "${attempt}" -ge "${retries}" ]; then
            echo "::error::${stage} [variant=${variant}]: every attempt failed fetching from a third-party host - check whether the hosts this stage installs from are degraded" >&2
            exit "${status}"
        fi

        echo "::warning::${stage} [variant=${variant}]: transient fetch failure - retrying in ${RETRY_PAUSE_SECONDS}s" >&2
        sleep "${RETRY_PAUSE_SECONDS}"
        attempt=$(( attempt + 1 ))
    done
done
