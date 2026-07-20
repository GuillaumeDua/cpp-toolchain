#!/bin/bash

set -eu

# =============================================================================================
# This file is part of https://github.com/GuillaumeDua/CppShelf,
# and will soon be part of https://hub.docker.com/repository/docker/gussd/cpp-toolchain/general
# License: see https://github.com/GuillaumeDua/CppShelf/blob/main/LICENSE
#
# Cross-compilation GNU binutils (as/ld/objdump/... for a target arch) + the matching cross-libc.
#   Compiler-agnostic:
#       The target `binutils-<triplet>` serve any toolchain emitting that arch (in this image, notably Clang's `--target=<triplet>`),
#       which is why they live here rather than in gcc.sh - see gcc.sh for the GCC-specific `--multilib`.
#
#       For each target we also install `libc6-dev-<debarch>-cross` (headers + crt + static, pulling the runtime)
#       so the target is actually linkable, not just assemble-able.
#
# Scope / known limitation: this enables *C* cross-compilation (cross binutils + cross glibc).
#   Cross-compiling *C++* additionally needs a *target* C++ standard library, which is NOT bundled:
#     - libc++   (LLVM): no portable apt cross package - requires an LLVM `runtimes` source build (possibly a future scripts/libcxx.sh).
#                        The *host* libc++ is installed by llvm.sh, so native `clang++ -stdlib=libc++` already works without GCC.
#     - libstdc++ (GNU): obtainable per target via `g++-<triplet>` / `libstdc++-<N>-dev-<debarch>-cross`.
# =============================================================================================

this_script_name=$(basename "$0")

arg_targets='aarch64-linux-gnu powerpc64-linux-gnu'
arg_list=0
arg_silent=1

help(){
    echo "Usage: ${this_script_name}" 1>&2
    echo "
    Boolean values: y|yes|1|true or n|no|0|false (case insensitive)

        [ -l | --list ]     : Only list the cross-binutils target triplets available on this host.  Boolean -> default is [0]
        [ -t | --targets ]  : Target triplets to install, as \`binutils-<triplet>\`.                String (space-separated) -> default is ['${arg_targets}']
                              Ex: 'aarch64-linux-gnu powerpc64-linux-gnu arm-linux-gnueabihf'
        [ -s | --silent ]   : Run in silent mod.                                                    Boolean -> default is [1]
        [ -h | --help ]     : Display usage/help

    For instance, to install only the aarch64 cross-binutils, use:
        sudo ./${this_script_name} --targets='aarch64-linux-gnu'
        " 1>&2
    exit 0
}
error(){
    echo -e "[${this_script_name}]: $@" >> /dev/stderr
    exit 1
}
log(){
    if [[ "${arg_silent}" == 1 ]]; then
        return 0;
    fi
    echo -e "[${this_script_name}]: $@"
}
to_boolean(){
    if [[ $# != 1 ]]; then
        error "$0: missing argument"
        exit 1
    fi
    case "$1" in
        [Yy]|[Yy][Ee][Ss]|1|[Tt][Rr][Uu][Ee]) echo 1;;
        [Nn]|[Nn][Oo]|0|[Ff][Aa][Ll][Ss][Ee]) echo 0;;
        *)
            error "to_boolean: invalid conversion from [$1] to boolean"
            exit 1
            ;;
    esac
}

# Map a GNU target triplet (as used by `binutils-<triplet>`) to the Debian architecture alias (as used by `libc6-dev-<debarch>-cross`).
# Empty output => no known cross-libc for that target.
triplet_to_debarch(){
    case "$1" in
        aarch64-linux-gnu)                 echo arm64    ;;
        arm-linux-gnueabihf)               echo armhf    ;;
        arm-linux-gnueabi)                 echo armel    ;;
        powerpc64-linux-gnu)               echo ppc64    ;;
        powerpc64le-linux-gnu)             echo ppc64el  ;;
        powerpc-linux-gnu)                 echo powerpc  ;;
        riscv64-linux-gnu)                 echo riscv64  ;;
        s390x-linux-gnu)                   echo s390x    ;;
        mips64el-linux-gnuabi64)           echo mips64el ;;
        i686-linux-gnu | i386-linux-gnu)   echo i386     ;;
        x86-64-linux-gnu | x86_64-linux-gnu) echo amd64  ;;
        *)                                 echo ''       ;;
    esac
}

# --- precondition: sudoer ---

if [ "$EUID" -ne 0 ]; then
  error "Requires root privileges"
  exit 1
fi

# --- options management ---

options_short=s:,t:,l,h
options_long=silent:,targets:,help,list
getopt_result=$(getopt -a -n ${this_script_name} --options ${options_short} --longoptions ${options_long} -- "$@")

eval set -- "$getopt_result"

while :
do
  case "$1" in
    -s | --silent )
      arg_silent="$2"
      shift 2
      ;;
    -t | --targets )
      arg_targets=$(echo $2 | tr -d '\n' | tr '\n' ' ')
      shift 2
      ;;
    -l | --list )
      arg_list=1
      shift;
      ;;
    -h | --help)
      help
      exit 0
      shift
      ;;
    --)
      shift;
      break
      ;;
    *)
      echo "${this_script_name}: Unexpected option: [$1]" >> /dev/stderr
      help
      ;;
  esac
done

arg_silent=$(to_boolean "${arg_silent}")
if [ "$arg_silent" == '' ] ; then
    exit 1;
fi

arg_list=$(to_boolean "${arg_list}")
if [ "$arg_list" == '' ] ; then
    exit 1;
fi

log "arguments - targets: [${arg_targets}]"
log "arguments - silent:  [${arg_silent}]"
log "arguments - list:    [${arg_list}]"

# --- list mod ? ---
#   lists the target triplets for which a `binutils-<triplet>` cross package exists on this host.
if [[ ${arg_list} == 1 ]]; then
    apt-get update -qqy >/dev/null 2>&1 || true
    #   `-dbg`/`-dev` are debug-symbol / side packages of a target, not targets themselves.
    apt-cache search --names-only '^binutils-.*-linux-gnu' \
        | awk '{print $1}' | grep -oP '^binutils-\K.*-linux-gnu.*$' \
        | grep -vE -- '-(dbg|dev)$' | sort -u
    exit 0
fi

# --- installations ---
apt-get update -qqy

for target in ${arg_targets}; do

    pkg_binutils="binutils-${target}"
    log "installing [${pkg_binutils}] ..."
    apt install -qq -y --no-install-recommends "${pkg_binutils}" \
        || log "[${pkg_binutils}] not available for this host/arch, skipping"

    # cross-libc for the same target (dev variant pulls the runtime), keyed off the Debian arch.
    debarch=$(triplet_to_debarch "${target}")
    if [ -z "${debarch}" ]; then
        log "no known cross-libc mapping for target [${target}], skipping its libc"
        continue
    fi
    pkg_libc="libc6-dev-${debarch}-cross"
    log "installing [${pkg_libc}] ..."
    apt install -qq -y --no-install-recommends "${pkg_libc}" \
        || log "[${pkg_libc}] not available for this host/arch, skipping"

done

exit 0;
