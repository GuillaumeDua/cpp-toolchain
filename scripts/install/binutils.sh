#!/bin/bash

set -eu

# =============================================================================================
# This file is part of https://github.com/GuillaumeDua/cpp-toolchain
# License: see https://github.com/GuillaumeDua/cpp-toolchain/blob/main/LICENSE
#
# Cross-compilation GNU toolchain(s) for one or more target architectures.
#
#   Primary path (per target):
#       install `g++-<triplet>`, which pulls the complete cross toolchain:
#       - cross binutils (as/ld/objdump)
#       - cross glibc
#       - cross libgcc AND cross libstdc++
#       all laid out under /usr/lib/gcc-cross/<triplet>/.
#
#       That is enough to compile and link C and C++ for the target.
#       Clang's driver auto-detects the cross-GCC install, so `clang --target=<triplet>` works too (using libstdc++, no extra flags).
#       This is the "with GCC" cross path.
#
#   Fallback (targets with no `g++-<triplet>` - e.g. ia64 / hppa64 / loongarch64 / mips-n32 variants, or when `--with-gcc=no`):
#       install `binutils-<triplet>` + `libc6-dev-<debarch>-cross` only.
#       Enough to compile to objects and inspect/strip, but NOT to link a full C/C++ executable (no target libgcc / libstdc++).
#       Kept compiler-agnostic - the bare binutils serve any toolchain.
#
#   NOT bundled - the "without GCC" cross path (Clang + libc++ for the target, no GNU runtime):
#       it has no portable apt package and needs an LLVM `runtimes` source build - tracked as a future scripts/libcxx.sh.
#       (Host libc++ is installed by llvm.sh, so native `clang++ -stdlib=libc++` already works without GCC - only the cross case is missing.)
# =============================================================================================

this_script_name=$(basename "$0")

# The triplets a cross build targets unless told otherwise, and the only place they are listed.
# Referred to as `common` so nothing downstream has to repeat them.
#
# Which triplets belong here is a judgement call rather than a fixed set:
# these are the architectures most cross builds are likely to want today, so expect the value to change as that answer does.
# No code repeats it - callers pass `common` through and let this script resolve it.
common_targets='aarch64-linux-gnu arm-linux-gnueabihf riscv64-linux-gnu x86-64-linux-gnu'

arg_targets='common'
arg_with_gcc=1
arg_targets_explicit=0
arg_list_available=0
arg_list_installed=0
arg_list_targets=0
arg_silent=1

help(){
    echo "Usage: ${this_script_name}" 1>&2
    echo "
    Boolean values: y|yes|1|true or n|no|0|false (case insensitive)

        [ -l | --list-available ] : Only list the cross target triplets available on this host, restricted to [targets].
                                    Use --targets=all to list every triplet this host offers.                               Boolean -> default is [0]
        [ --list-installed ]      : Only list the cross target triplets already installed, restricted to [targets] when given explicitly.
                                                                                                                            Boolean -> default is [0]
        [ --list-targets ]        : Only print the triplets [targets] resolves to, without consulting apt.                  Boolean -> default is [0]
        [ -t | --targets ]        : Target triplets to install a cross toolchain for (space-separated),                     String -> default is ['${arg_targets}']
                                    or 'common' (${common_targets}),
                                    or 'all' (every triplet this host offers).
                                    Ex: 'aarch64-linux-gnu powerpc64le-linux-gnu s390x-linux-gnu'
        [ --with-gcc ]            : Install \`g++-<triplet>\` -> full cross toolchain (binutils+libc+libgcc+libstdc++).     Boolean -> default is [1]
                                    When [0], or when no cross-g++ exists: \`binutils-<triplet>\` + \`libc6-dev-<debarch>-cross\` only.
        [ -s | --silent ]         : Run in silent mod.                                                                      Boolean -> default is [1]
        [ -h | --help ]           : Display usage/help

    For instance, to install only the aarch64 cross-binutils, use:
        sudo ./${this_script_name} --targets='aarch64-linux-gnu'
        " 1>&2
    exit 0
}

error_diagnosis(){
    {
        echo -e "[${this_script_name}]: diagnosis helper:"
        if command -v lsb_release >/dev/null 2>&1; then
            echo -e "\t- distribution:       [$(lsb_release -ds 2>/dev/null)]"
        fi
        echo -e "\t- host architecture:  [$(dpkg --print-architecture 2>/dev/null)]"
        echo -e "\t- targets requested:  [${arg_targets}]"
        echo -e "\t- with gcc:           [${arg_with_gcc}]"
    } >> /dev/stderr
}
error(){
    echo -e "[${this_script_name}]: $@" >> /dev/stderr
    error_diagnosis
    exit 1
}
warning(){
    echo -e "[${this_script_name}]: $@" >> /dev/stderr
}
log(){
    if [[ "${arg_silent}" == 1 ]]; then
        return 0;
    fi
    echo -e "[${this_script_name}]: $@"
}
# Runs a command quietly, replaying its output only if it fails.
run(){
    local what="$1"; shift
    local output streamed=0 status=0

    output=$(mktemp)
    if [[ "${arg_silent}" == 0 ]]; then
        # stderr, because stdout carries the result to the caller.
        streamed=1
        "$@" 2>&1 | tee "${output}" >&2
        status=${PIPESTATUS[0]}
    else
        "$@" > "${output}" 2>&1 || status=$?
    fi

    if [ "${status}" -eq 0 ]; then
        rm -f "${output}"
        return 0
    fi

    {
        echo -e "[${this_script_name}]: ${what} failed - exit status [${status}]"
        echo -e "[${this_script_name}]: command: [$*]"
        if [ "${streamed}" -eq 0 ]; then
            echo -e "[${this_script_name}]: --- output ---"
            cat "${output}"
            echo -e "[${this_script_name}]: --- end of output ---"
        fi
    } >> /dev/stderr
    rm -f "${output}"
    return "${status}"
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
triplet_to_deb_arch(){
    case "$1" in
        # --- arm ---
        aarch64-linux-gnu)                   echo arm64      ;;
        arm-linux-gnueabihf)                 echo armhf      ;;  # hard-float FPU ABI
        arm-linux-gnueabi)                   echo armel      ;;  # soft-float FPU ABI
        # --- x86 ---
        x86-64-linux-gnu | x86_64-linux-gnu) echo amd64      ;;
        x86-64-linux-gnux32)                 echo x32        ;;  # x32 ABI
        i686-linux-gnu | i386-linux-gnu)     echo i386       ;;
        # --- powerpc ---
        powerpc-linux-gnu)                   echo powerpc    ;;
        powerpc64-linux-gnu)                 echo ppc64      ;;  # big-endian
        powerpc64le-linux-gnu)               echo ppc64el    ;;  # little-endian
        # --- mips: o32 / n32 / n64 ABIs, r6 ISA, both endiannesses ---
        mips-linux-gnu)                      echo mips       ;;
        mipsel-linux-gnu)                    echo mipsel     ;;
        mips64-linux-gnuabi64)               echo mips64     ;;
        mips64el-linux-gnuabi64)             echo mips64el   ;;
        mips64-linux-gnuabin32)              echo mipsn32    ;;
        mips64el-linux-gnuabin32)            echo mipsn32el  ;;
        mipsisa32r6-linux-gnu)               echo mipsr6     ;;
        mipsisa32r6el-linux-gnu)             echo mipsr6el   ;;
        mipsisa64r6-linux-gnuabi64)          echo mips64r6   ;;
        mipsisa64r6el-linux-gnuabi64)        echo mips64r6el ;;
        mipsisa64r6-linux-gnuabin32)         echo mipsn32r6  ;;
        mipsisa64r6el-linux-gnuabin32)       echo mipsn32r6el;;
        # --- others ---
        riscv64-linux-gnu)                   echo riscv64    ;;
        s390x-linux-gnu)                     echo s390x      ;;
        loongarch64-linux-gnu)               echo loong64    ;;
        sparc64-linux-gnu)                   echo sparc64    ;;
        hppa-linux-gnu)                      echo hppa       ;;
        m68k-linux-gnu)                      echo m68k       ;;
        sh4-linux-gnu)                       echo sh4        ;;
        arc-linux-gnu)                       echo arc        ;;
        # no cross-libc published for these, binutils only: alpha, hppa64, ia64
        *)                                   echo ''         ;;
    esac
}

# --- list targets ---
#   `-dbg`/`-dev` are debug-symbol / side packages of a target, not targets themselves.
target_triplets(){
    grep -oP '^binutils-\K.*-linux-gnu.*$' | grep -vE -- '-(dbg|dev)$' | sort -u
}

list_available_targets(){
    run "refreshing the apt index" apt-get update -q -y -o Acquire::Retries=3 \
    || warning "refreshing the apt index failed - the target list below may be incomplete or empty"
    apt-cache search --names-only '^binutils-.*-linux-gnu' | awk '{print $1}' | target_triplets
}

list_installed_targets(){
    dpkg-query --show --showformat='${Package} ${Status}\n' 2>/dev/null \
      | awk '$2 == "install" && $4 == "installed" { print $1 }' | target_triplets
}

# Resolve the `common` alias. `all` needs the apt index, so it is left to the modes that have one.
expand_targets(){
    if [ "$1" = 'common' ]; then
        echo "${common_targets}"
    else
        echo "$1"
    fi
}

# Restrict a set of triplets to a --targets selector.
#   'all' keeps the set as-is, an explicit list is intersected with it.
select_targets(){
    local selector="$1"
    local targets="$2"

    if [ "${selector}" = 'all' ]; then
        echo "${targets}"
        return
    fi
    local requested
    for requested in ${selector}; do
        grep -qx -- "${requested}" <<< "${targets}" && echo "${requested}"
    done
}

# --- options management ---

options_short=s:,t:,l,h
options_long=silent:,targets:,with-gcc:,help,list-available,list-installed,list-targets
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
      arg_targets_explicit=1
      shift 2
      ;;
    --with-gcc )
      arg_with_gcc="$2"
      shift 2
      ;;
    -l | --list-available )
      arg_list_available=1
      shift;
      ;;
    --list-installed )
      arg_list_installed=1
      shift;
      ;;
    --list-targets )
      arg_list_targets=1
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

arg_list_available=$(to_boolean "${arg_list_available}")
if [ "$arg_list_available" == '' ] ; then
    exit 1;
fi

arg_list_installed=$(to_boolean "${arg_list_installed}")
if [ "$arg_list_installed" == '' ] ; then
    exit 1;
fi

arg_list_targets=$(to_boolean "${arg_list_targets}")
if [ "$arg_list_targets" == '' ] ; then
    exit 1;
fi

arg_with_gcc=$(to_boolean "${arg_with_gcc}")
if [ "$arg_with_gcc" == '' ] ; then
    exit 1;
fi

log "arguments - targets:           [${arg_targets}]"
log "arguments - with-gcc:          [${arg_with_gcc}]"
log "arguments - silent:            [${arg_silent}]"
log "arguments - list-available:    [${arg_list_available}]"
log "arguments - list-installed:    [${arg_list_installed}]"
log "arguments - list-targets:      [${arg_list_targets}]"

# Resolved once, so every mode below sees a plain triplet list rather than an alias.
if [ "${arg_targets}" != 'all' ]; then
    arg_targets=$(expand_targets "${arg_targets}")
fi

# --- list targets mod ? ---
#   Pure expansion: no root, no apt, so anything downstream can resolve `common` for itself.
if [[ ${arg_list_targets} == 1 ]]; then
    [ "${arg_targets}" != 'all' ] \
      || error "--list-targets cannot expand [all] without the apt index - use --list-available --targets=all"
    for target in ${arg_targets}; do
        echo "${target}"
    done
    exit 0
fi

# --- list installed mod ? ---
#   Answered from dpkg alone, so this stays a query: no root, no apt index refresh.
if [[ ${arg_list_installed} == 1 ]]; then
    installed_targets=$(list_installed_targets)
    if [[ ${arg_targets_explicit} == 1 ]]; then
        select_targets "${arg_targets}" "${installed_targets}"
    elif [ -n "${installed_targets}" ]; then
        echo "${installed_targets}"
    fi
    exit 0
fi

# --- precondition: sudoer ---

if [ "$EUID" -ne 0 ]; then
  error "Requires root privileges"
  exit 1
fi

# --- list mod ? ---
if [[ ${arg_list_available} == 1 ]]; then
    select_targets "${arg_targets}" "$(list_available_targets)"
    exit 0
fi

# --- installations ---
if [ "${arg_targets}" = 'all' ]; then
    arg_targets=$(list_available_targets | tr '\n' ' ')
fi
run "refreshing the apt index" apt-get update -q -y -o Acquire::Retries=3 \
|| error "refreshing the apt index failed"

for target in ${arg_targets}; do

    # Primary: the cross g++ transitively pulls the whole toolchain (binutils + libc + libgcc + libstdc++),
    #   so this single package makes C and C++ cross-compilation actually link,
    #   and Clang auto-detects the cross-GCC install, so `clang --target=${target}` works too.
    if [[ ${arg_with_gcc} == 1 ]] && apt install -qq -y --no-install-recommends -o Acquire::Retries=3 "g++-${target}"; then
        log "[g++-${target}] installed - full cross toolchain (binutils + libc + libgcc + libstdc++)"
        continue
    fi
    if [[ ${arg_with_gcc} == 1 ]]; then
        warning "[g++-${target}] unavailable, falling back to binutils + cross-libc only"
    fi

    # Fallback: bare cross binutils (+ cross libc, keyed off the Debian arch).
    #   Enough to compile to objects and inspect/strip; NOT to link a full executable (no target libgcc / libstdc++).
    pkg_binutils="binutils-${target}"
    log "installing [${pkg_binutils}] ..."
    apt install -qq -y --no-install-recommends -o Acquire::Retries=3 "${pkg_binutils}" \
        || warning "[${pkg_binutils}] not available for this host/arch, skipping"

    debarch=$(triplet_to_deb_arch "${target}")
    if [ -z "${debarch}" ]; then
        log "no known cross-libc mapping for target [${target}], skipping its libc"
        continue
    fi
    pkg_libc="libc6-dev-${debarch}-cross"
    log "installing [${pkg_libc}] ..."
    apt install -qq -y --no-install-recommends -o Acquire::Retries=3 "${pkg_libc}" \
        || warning "[${pkg_libc}] not available for this host/arch, skipping"

done

exit 0;
