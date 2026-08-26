#!/bin/bash

set -eu

# =============================================================================================
# This file is part of https://github.com/GuillaumeDua/cpp-toolchain
# License: see https://github.com/GuillaumeDua/cpp-toolchain/blob/main/LICENSE
# =============================================================================================

this_script_name=$(basename "$0")

arg_versions='latest-stable'
arg_versions_explicit=0
arg_list_available=0
arg_list_installed=0
arg_silent=1
arg_alias=0
arg_multilib=1
arg_multilib_explicit=0
arg_minimalistic=0
arg_mode='full'

# How many times a network-facing step is attempted
max_attempts=3

help(){
    echo "Usage: ${this_script_name}" 1>&2
    echo "
    Boolean values: y|yes|1|true or n|no|0|false (case insensitive)

        [ -l | --list-available ]: Only list available versions, expanding [versions].              Boolean -> default is [0]
        [ --list-installed ]     : Only list the major versions already installed.                  Boolean -> default is [0]
                                   Filtered by [versions] when given explicitly, otherwise every installed major is listed.
        [ -v | --versions ]      : Versions to install.                                             String: all|latest|latest-stable|>=(number)|(space-separated-numbers...) -> default is [latest-stable]
            - [all]              : all versions availables                                              Ex: 'all'
            - [latest]           : only the latest        version available                             Ex: 'latest'
            - [latest-stable]    : only the latest-stable version available                             Ex: 'latest-stable'
            - [>=(number)]       : all versions greater or equal to <number>.                           Ex: '>=42'
            - [numbers...]       : only listed versions.                                                Ex: '13 25 42' (space-separated)
        [ -s | --silent ]        : Run in silent mod.                                               Boolean -> default is [1]
        [ -a | --alias]          : Set bash/zsh-rc aliases.                                         Boolean -> default is [0]
        [ --multilib ]           : install gcc/g++ multilib (32-bit / x32 secondary ABI).           Boolean -> default is [1]
        [ --mode ]               : How much of the toolchain to install.                            String: runtime|minimalistic|full -> default is [full]
            - [runtime]          : the C++ runtime alone (libstdc++6, libgcc-s1) - no compiler.
                                   For an image that runs what another one built.
            - [minimalistic]     : compilers only - disables multilib unless it is explicitly set
            - [full]             : compilers and multilib
        [ -m | --minimalistic]   : Alias for --mode=minimalistic, kept for compatibility.           Boolean -> default is [0]
        [ -h | --help ]          : Display usage/help

    For instance, to only install the two latest versions available, use:
        sudo ./${this_script_name} --versions=\"\$(sudo ./${this_script_name} --list-available --versions='all' | tail -2)\"
        " 1>&2
    exit 0
}
error_diagnosis(){
    local sources
    sources=$(grep -rl 'ubuntu-toolchain-r' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | paste -sd' ' -)
    {
        echo -e "[${this_script_name}]: diagnosis helper:"
        if command -v lsb_release >/dev/null 2>&1; then
            echo -e "\t- distribution:         [$(lsb_release -ds 2>/dev/null)]"
        fi
        echo -e "\t- mode:                 [${arg_mode}]"
        echo -e "\t- versions requested:   [${arg_versions}]"
        echo -e "\t- toolchain PPA source: [${sources:-<none registered>}]"
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
# Launchpad is a third-party host: a transient refusal should not sink a whole image build.
# Only the last attempt reports.
retry(){
    local attempts="$1" what="$2"; shift 2
    local attempt=1

    while [ "${attempt}" -lt "${attempts}" ]; do
        "$@" > /dev/null 2>&1 && return 0
        warning "${what} failed - retrying in $(( attempt * 5 ))s (attempt $(( attempt + 1 ))/${attempts})"
        sleep $(( attempt * 5 ))
        attempt=$(( attempt + 1 ))
    done
    "$@"
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

# --- options management ---

options_short=s:,v:,a:,m,l,h
options_long=silent:,versions:,alias:,multilib:,minimalistic,mode:,help,list-available,list-installed
getopt_result=$(getopt -a -n ${this_script_name} --options ${options_short} --longoptions ${options_long} -- "$@")

eval set -- "$getopt_result"

while :
do
  case "$1" in
    -s | --silent )
      arg_silent="$2"
      shift 2
      ;;
    -a | --alias )
      arg_alias="$2"
      shift 2
      ;;
    -v | --versions )
      arg_versions=$(echo $2 | tr -d '\n' | tr '\n' ' ')
      arg_versions_explicit=1
      shift 2
      ;;
    --multilib )
      arg_multilib="$2"
      arg_multilib_explicit=1
      shift 2
      ;;
    -m | --minimalistic )
      arg_minimalistic=1
      shift;
      ;;
    --mode )
      arg_mode="$2"
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

arg_multilib=$(to_boolean "${arg_multilib}")
if [ "$arg_multilib" == '' ] ; then
    exit 1;
fi

arg_minimalistic=$(to_boolean "${arg_minimalistic}")
if [ "$arg_minimalistic" == '' ] ; then
    exit 1;
fi

# --minimalistic is an alias for --mode=minimalistic, so it folds into the mode.
#   It only wins where --mode is defaulted, the same way it treats --multilib below:
#       naming both is a caller being explicit about the mode, and that is the one that is honored.
if [[ ${arg_minimalistic} == 1 ]] && [[ "${arg_mode}" == 'full' ]]; then
    arg_mode='minimalistic'
fi

case "${arg_mode}" in
    runtime | minimalistic | full ) ;;
    * ) error "invalid --mode=[${arg_mode}] - expected one of: runtime, minimalistic, full" ;;
esac

# Only `minimalistic` trims multilib, and only where --multilib is defaulted: an explicit --multilib=yes still wins.
#   `runtime` installs no compiler at all, so it has no secondary ABI to install one for.
if [[ "${arg_mode}" == 'minimalistic' ]] && [[ ${arg_multilib_explicit} == 0 ]]; then
    arg_multilib=0
fi

# --- list installed versions ---
#   Answered from dpkg alone, so this stays a query: no root, no repository added, nothing fetched.
#   The trailing anchor keeps gcc-<major>-base and gcc-<major>-multilib out.
#   Those are metadata and secondary-ABI packages that libgcc-s1 and libstdc++6 drag in,
#   so an image can carry them for a major it has no compiler for.
gcc_version_installed_regex='^gcc-\K[0-9]+(?=(:.*)?$)'
list_installed_gcc_versions(){
    dpkg -l | grep ^ii | awk '{print $2}' | grep -oP "${gcc_version_installed_regex}" | sort -n -u
}

# Filter a set of majors by a --versions selector.
#   This reports what is present rather than what could be installed,
#   so an explicit list is intersected with the set rather than passed through.
select_versions(){
    local selector="$1"
    local versions="$2"

    case "${selector}" in
        all )
            echo "${versions}" ;;
        latest | latest-stable )
            echo "${versions}" | tail -1 ;;
        '>='[0-9]* )
            local from
            from=$(echo "${selector}" | grep -oP '^>=\K[0-9]+$')
            [ -n "${from}" ] || error "invalid version='>=[0-9]+' value: [${selector}]"
            echo "${versions}" | awk -v from="${from}" '$1 >= from' ;;
        * )
            [[ "${selector}" =~ ^[0-9]+( [0-9]+)*$ ]] \
                || error "invalid value for argument version [${selector}]"
            local requested
            for requested in ${selector}; do
                grep -qx -- "${requested}" <<< "${versions}" && echo "${requested}"
            done ;;
    esac
}

if [[ ${arg_list_installed} == 1 ]]; then
    installed_versions=$(list_installed_gcc_versions)
    if [[ ${arg_versions_explicit} == 1 ]]; then
        select_versions "${arg_versions}" "${installed_versions}"
    elif [ -n "${installed_versions}" ]; then
        echo "${installed_versions}"
    fi
    exit 0
fi

# --- precondition: sudoer ---

if [ "$EUID" -ne 0 ]; then
  error "Requires root privileges"
  exit 1
fi

log "arguments - versions:       [${arg_versions}]"
log "arguments - silent:         [${arg_silent}]"
log "arguments - alias:          [${arg_alias}]"
log "arguments - list-available: [${arg_list_available}]"
log "arguments - multilib:       [${arg_multilib}]"
log "arguments - mode:           [${arg_mode}]"

# --- use ppa:ubuntu-toolchain-r/test

ubuntu_toolchain_r_ppa="ubuntu-toolchain-r/test"
is_ubuntu_toolchain_r_ppa_added=$(grep -r "${ubuntu_toolchain_r_ppa}" /etc/apt/sources.list.d/ >/dev/null 2>&1 && echo true || echo false)
if [ "${is_ubuntu_toolchain_r_ppa_added}" = false ]; then
    log "adding ppa: [${ubuntu_toolchain_r_ppa}] ..."
    # Unchecked, a failure here leaves the distro's own gcc as the only candidate,
    # surfacing much later as a requested version that is "not available".
    retry "${max_attempts}" "adding ppa [${ubuntu_toolchain_r_ppa}]" \
        add-apt-repository -y "ppa:${ubuntu_toolchain_r_ppa}" \
    || error "adding ppa [${ubuntu_toolchain_r_ppa}] failed"
    retry "${max_attempts}" "refreshing the apt index" apt update -qqy -o Acquire::Retries=${max_attempts} \
    || error "refreshing the apt index failed"
fi

# --- runtime mode ---
#   Answered here, above the version machinery, because it has no version to resolve:
#       libstdc++6 and libgcc-s1 are one-per-system packages carrying no major in their name,
#       so `--versions` selects nothing, and the "empty versions range" error would fire on a well-formed request.
#   These are the two packages the image validation gate expects from this PPA,
#   so naming them here keeps that one fact in one place (scripts/checks/details/package-origins.sh).
if [[ "${arg_mode}" == 'runtime' ]]; then
    log "installing the C++ runtime libraries ..."
    apt install -qq -y --no-install-recommends -o Acquire::Retries=${max_attempts} \
            libstdc++6 libgcc-s1                                                   \
        || error "installation of the runtime libraries failed"
    exit 0
fi

# --- list versions ---
gcc_version_available_regex='^gcc-\K([0-9]{2})(?=/)'

# --- which versions ---
all_gcc_versions_available=$(apt list --all-versions 2>/dev/null | grep -oP "${gcc_version_available_regex}" | sort -n -u)
if [ "$arg_versions" = 'all' ]; then
    gcc_versions=$all_gcc_versions_available
elif [ "$arg_versions" = 'latest' ] || [ "$arg_versions" = 'latest-stable' ]; then
    gcc_versions=$(echo ${all_gcc_versions_available} | tr " " "\n" | tail -1)
elif [[ "$arg_versions" =~  ^\>=[0-9]+$ ]]; then
    from_version=$(echo "${arg_versions}" | grep -oP '^>=\K([0-9])+$')
    log "using user-provided rule: >=[$from_version]"
    if [ -z "$from_version" ]; then
        error "invalid version='>=[0-9]+' value"
        exit 1
    fi
    gcc_versions=$(echo "$all_gcc_versions_available" | awk "\$1 >= ${from_version}")
elif [[ "$arg_versions" =~  ^[0-9]+( [0-9]+)*$ ]]; then
    log "using user-provided version(s) list: [${arg_versions}]"
    gcc_versions="${arg_versions}"
elif [ ! -z "$arg_versions" ]; then
    error "invalid value for argument version [${arg_versions}]"
    exit 1
fi

if [ -z "$gcc_versions" ]; then
    error "empty request versions range [${gcc_versions}] , nothing to do. Available versions: [${all_gcc_versions_available}], requested versions: [${arg_versions}](${from_version})"
    echo -e "$(list_installed_gcc_versions)" # result for the caller
    exit 0
fi
if [[ ! $(echo -n $gcc_versions) =~  ^[0-9]+( [0-9]+)*$ ]]; then
    error "invalid versions range: [$gcc_versions]"
    exit 1
fi

## --- list mod ? ---
if [[ ${arg_list_available} == 1 ]]; then
    echo -e "${gcc_versions}"
    exit 0
fi

log "GCC version(s) to be installed: [${gcc_versions}]"

# --- installations ---
mapfile -t gcc_versions_to_install < <(echo -n "$gcc_versions")

for version in "${gcc_versions_to_install[@]}"; do
    log "installing ${version} ..."

    apt install -qq -y --no-install-recommends -o Acquire::Retries=${max_attempts} \
            gcc-${version} g++-${version}                                          \
        || error "installation of [${version}] failed"
    if [[ ${arg_multilib} == 1 ]]; then
        # multilib availability is environmental:
        #   It lags for brand-new toolchain versions, and does not exist on non-amd64 hosts.
        #   So a default (implicit) request is best-effort - skip with a warning - while an explicit --multilib=yes is honored strictly and fails hard if unavailable.
        if ! apt install -qq -y --no-install-recommends -o Acquire::Retries=${max_attempts} \
                gcc-${version}-multilib g++-${version}-multilib                             \
        ; then
            if [[ ${arg_multilib_explicit} == 1 ]]; then
                error "multilib for [${version}] explicitly requested (--multilib) but not available"
            fi
            warning "multilib for [${version}] not available, skipping"
        fi
    fi
    # NOTE: no cross-target alternative is registered here.
    #   The per-target `g++-<triplet>` toolchains are binutils.sh's, and they are not published uniformly across majors.
    update-alternatives --quiet                                                        \
            --install /usr/bin/gcc       gcc       /usr/bin/gcc-${version} ${version}  \
            --slave   /usr/bin/g++       g++       /usr/bin/g++-${version}             \
            --slave   /usr/bin/gcov      gcov      /usr/bin/gcov-${version}            \
            --slave   /usr/bin/gcov-tool gcov-tool /usr/bin/gcov-tool-${version}       \
        || error "update-alternatives of [${version}] failed"

done

# --- summary ---
gcc_versions=$(list_installed_gcc_versions)
log "GCC versions now detected: [$(echo -e $(list_installed_gcc_versions))]" 
echo -e "${gcc_versions}" # result for the caller

# --- Create aliases ---
arg_alias=$(to_boolean "${arg_alias}")
if [ "$arg_alias" == '' ] ; then
    exit 1;
fi

if [[ "${arg_alias}" == 1 ]]; then
    log "alias: adding aliases for [bash zsh]"
    [[ -f '/etc/bash.bashrc' ]] && echo gcc_versions=\'${gcc_versions}\' >> /etc/bash.bashrc;
    [[ -f '/etc/zsh/zshrc' ]]   && echo gcc_versions=\'${gcc_versions}\' >> /etc/zsh/zshrc;
fi

exit 0;
