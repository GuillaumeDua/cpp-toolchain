#!/bin/bash

set -eu

# =============================================================================================
# This file is part of https://github.com/GuillaumeDua/cpp-toolchain
# License: see https://github.com/GuillaumeDua/cpp-toolchain/blob/main/LICENSE
#
# Build and install include-what-you-use (https://include-what-you-use.org) against an LLVM
# already installed here. Upstream publishes source alone.
#
# IWYU reads clang's internals: one release builds against one clang major, per the compatibility
# table in the upstream README. A mismatch fails the compile.
# =============================================================================================

this_script_name=$(basename "$0")

arg_version=''
arg_llvm_version=''
arg_prefix='/usr/local'
arg_silent=1

max_attempts=3

# github.com publishes no throttling window - a plain transient-failure backoff.
retry_backoff_seconds=5

work_dir=''
llvm_root=''

help(){
    echo "Usage: ${this_script_name} --version=<tag> --llvm-version=<major> [options]" >&2
    echo "
    Boolean values: y|yes|1|true or n|no|0|false (case insensitive)

        [ -v | --version ]      : IWYU release tag to build.      String: (exact-version) -> required, Ex: '0.26'
        [ -l | --llvm-version ] : LLVM major to build against.    String: (major) -> required, Ex: '22'
        [ -p | --prefix ]       : Installation prefix.            String -> default is [${arg_prefix}]
        [ -s | --silent ]       : Run in silent mod.              Boolean -> default is [1]
        [ -h | --help ]         : Display usage/help

    Builds against /usr/lib/llvm-<major>, so llvm-<major>-dev, libclang-<major>-dev and
    clang-<major> have to be installed - llvm.sh --mode=full next door installs all three.

    There is no 'latest': a release builds against one clang major, so the pair is always named
    by the caller.
    " >&2
    exit 0
}

clean(){
    if [ -n "${work_dir}" ] && [ -d "${work_dir}" ]; then
        rm -rf "${work_dir}"
    fi
}
trap clean EXIT

error_diagnosis(){
    {
        echo -e "[${this_script_name}]: diagnosis helper:"
        echo -e "\t- IWYU version:       [${arg_version:-<unset>}]"
        echo -e "\t- LLVM root:          [${llvm_root:-<unresolved>}]"
        echo -e "\t- install prefix:     [${arg_prefix}]"
        echo -e "\t- clang:              [$(command -v clang 2>/dev/null || echo '<not on PATH>')]"
    } >&2
}

# Not composed standalone, unlike scripts/install/*.sh: read by relative path, so this one needs
# a checkout or an image.
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/../lib/shared.sh"

# --- options management ---

options_short=v:,l:,p:,s:,h
options_long=version:,llvm-version:,prefix:,silent:,help
getopt_result=$(getopt -a -n ${this_script_name} --options ${options_short} --longoptions ${options_long} -- "$@")

eval set -- "$getopt_result"

while :
do
  case "$1" in
    -v | --version )
        arg_version="$2"
        shift 2
        ;;
    -l | --llvm-version )
        arg_llvm_version="$2"
        shift 2
        ;;
    -p | --prefix )
        arg_prefix="$2"
        shift 2
        ;;
    -s | --silent )
        arg_silent="$2"
        shift 2
        ;;
    -h | --help )
        help
        ;;
    -- )
        shift
        break
        ;;
    * )
        error "unexpected option [$1]"
        ;;
  esac
done

arg_silent=$(to_boolean "${arg_silent}")

# --- preconditions ---

if [ -z "${arg_version}" ] || [ -z "${arg_llvm_version}" ]; then
    error "--version and --llvm-version are both required - see --help"
fi

llvm_root="/usr/lib/llvm-${arg_llvm_version}"

# The file CMake looks for, rather than the package, so a non-apt LLVM passes too.
[ -f "${llvm_root}/lib/cmake/clang/ClangConfig.cmake" ] \
|| error "no clang CMake package under [${llvm_root}] - install libclang-${arg_llvm_version}-dev and llvm-${arg_llvm_version}-dev"

# --- build ---

source_url="https://github.com/include-what-you-use/include-what-you-use/archive/refs/tags/${arg_version}.tar.gz"

work_dir=$(mktemp -d)
cd "${work_dir}"
mkdir source

run_with_retries "${max_attempts}" "fetching [${source_url}]" \
    curl --fail --silent --show-error --location --retry ${max_attempts} --output source.tar.gz "${source_url}" \
|| error "fetching [${source_url}] failed - is [${arg_version}] a published IWYU release?"

run "extracting [source.tar.gz]" \
    tar --extract --gzip --file source.tar.gz --directory source --strip-components=1 \
|| error "extracting [source.tar.gz] failed"

jobs=$(nproc)

# The clang being linked against compiles it. Left to CMake this is /usr/bin/c++, pinned nowhere.
# BUILD_WITH_INSTALL_RPATH: the install rewrites the runpath otherwise, so what ships is not what
# was built.
timed "configuring against [${llvm_root}]" \
    cmake -S source -B build -G Ninja                        \
          -DCMAKE_BUILD_TYPE=Release                         \
          -DCMAKE_PREFIX_PATH="${llvm_root}"                 \
          -DCMAKE_INSTALL_PREFIX="${arg_prefix}"             \
          -DCMAKE_C_COMPILER="${llvm_root}/bin/clang"        \
          -DCMAKE_CXX_COMPILER="${llvm_root}/bin/clang++"    \
          -DCMAKE_BUILD_WITH_INSTALL_RPATH=TRUE              \
|| error "configuring failed"

# The tool alone: no unit-tests.
timed "building [${jobs}] jobs" \
    cmake --build build --target include-what-you-use --parallel "${jobs}" \
|| error "building failed"

# The rest of the install set is published files, not build output.
timed "installing into [${arg_prefix}]" \
    cmake --install build \
|| error "installing into [${arg_prefix}] failed"

# The names the apt package used, kept for callers' scripts.
ln -sf "${arg_prefix}/bin/iwyu_tool.py"    "${arg_prefix}/bin/iwyu_tool"
ln -sf "${arg_prefix}/bin/fix_includes.py" "${arg_prefix}/bin/fix_include"

# --- summary ---

# Qualified, so these report what was just installed rather than whatever PATH resolves to.
"${arg_prefix}/bin/include-what-you-use" --version

# A resource directory outside this LLVM is a binary that cannot find stddef.h: it builds,
# installs, and fails on every file. IWYU prints the path then exits 1, so only the path answers.
resource_dir=$("${arg_prefix}/bin/include-what-you-use" -print-resource-dir) || true
[[ "${resource_dir}" == "${llvm_root}"/* ]] \
|| error "resource directory [${resource_dir}] is outside [${llvm_root}]"
echo "[${this_script_name}]: resource directory [${resource_dir}]"
