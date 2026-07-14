#!/bin/bash

set -eu

# =============================================================================================
# This file is part of https://github.com/GuillaumeDua/cpp-toolchain
# License: see https://github.com/GuillaumeDua/cpp-toolchain/blob/main/LICENSE
# =============================================================================================

this_script_name=$(basename "$0")

arg_versions='latest'
arg_list=0
arg_silent=1
arg_alias=0
arg_rc=0

internal_script_path='impl.sh'

help(){
    echo "Usage: ${this_script_name}" 1>&2
    echo "
    Boolean values: y|yes|1|true or n|no|0|false (case insensitive)

        [ -l | --list ]     : Only list available versions from the Kitware apt repository. Boolean -> default is [0]
        [ -v | --versions ] : Version to install.                                           String: latest|(exact-version) -> default is [latest]
            - [latest]      : the version apt would resolve by default (Candidate)              Ex: 'latest'
            - [x.y.z-...]   : an exact version, pinned via 'apt install cmake=<version>'        Ex: '3.29.3-0kitware1ubuntu24.04.1~jammy'
        [ -s | --silent ]   : Run in silent mod.                                            Boolean -> default is [1]
        [ -a | --alias]     : Set bash/zsh-rc 'cmake_version' alias.                        Boolean -> default is [0]
        [ -r | --rc ]       : Also register the Kitware release-candidate apt repository.   Boolean -> default is [0]
        [ -h | --help ]     : Display usage/help

    For instance, to list the versions currently available, then install one of them:
        sudo ./${this_script_name} --list
        sudo ./${this_script_name} --versions=\"3.29.3-0kitware1ubuntu24.04.1~jammy\"
        " 1>&2
    exit 0
}
clean(){
    if [ -f "${internal_script_path}" ]; then
        rm -rf "${internal_script_path}"
    fi
}
error_diagnosis(){
    is_lsb_release_installed=$(command -v lsb_release >/dev/null 2>&1 && echo true || echo false)
    if [ "${is_lsb_release_installed}" = true ]; then
        echo -e "[${this_script_name}]: diagnosis helper:"
        echo -e "\t- while running on [$(lsb_release -d)]" >> /dev/stderr
    fi
}
error(){
    echo -e "[${this_script_name}]: $@" >> /dev/stderr
    error_diagnosis
    clean; exit 1
}
log(){
    if [[ "${arg_silent}" == 1 ]]; then
        return 0;
    fi
    echo -e "[${this_script_name}]: $@"
    return 0
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

# --- precondition: sudoer ---

if [ "$EUID" -ne 0 ]; then
    error "Requires root privileges"
fi

# --- options management ---

options_short=s:,v:,a:,r,l,h
options_long=silent:,versions:,alias:,rc,help,list
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
        shift 2
        ;;
    -r | --rc )
        arg_rc=1
        shift;
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

arg_rc=$(to_boolean "${arg_rc}")
if [ "$arg_rc" == '' ] ; then
    exit 1;
fi

log "arguments - versions: [${arg_versions}]"
log "arguments - silent:   [${arg_silent}]"
log "arguments - alias:    [${arg_alias}]"
log "arguments - list:     [${arg_list}]"
log "arguments - rc:       [${arg_rc}]"

# --- register the Kitware apt repository (https://apt.kitware.com/) ---

if [ -f "${internal_script_path}" ]; then
    echo -e "temporary file [${internal_script_path}] already exists" >> /dev/stderr # not using error to avoid deleting the file
    exit 1
fi

external_script_url='https://apt.kitware.com/kitware-archive.sh'

# quick-fix: Ubuntu-24.04-noble not supported yet by kitware-archive.sh -> Ubuntu-22.04-jammy
codename=$(value=$(lsb_release -cs); [[ "${value}" == "noble" ]] && value="jammy"; echo "${value}")

wget -qO ${internal_script_path} ${external_script_url} \
    && chmod +x "${internal_script_path}"
if [ $? != 0 ] || [ ! -f "${internal_script_path}" ]; then
    error "fetching [${external_script_url}] failed"
fi

rc_option=$([[ "${arg_rc}" == 1 ]] && echo '--rc' || echo '')
./${internal_script_path} --release ${codename} ${rc_option} \
    || error "running [${external_script_url} --release ${codename} ${rc_option}] failed"
clean

apt update -qqy

# --- list versions ---

all_cmake_versions_available=$(apt-cache madison cmake | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' | sort -V | uniq)
if [ -z "${all_cmake_versions_available}" ]; then
    error "no cmake version found via apt-cache madison, is the Kitware apt repository reachable?"
fi

## --- list mod ? ---
if [[ ${arg_list} == 1 ]]; then
    echo -e "${all_cmake_versions_available}"
    exit 0
fi

# --- which version ---

if [ "$arg_versions" = 'latest' ]; then
    cmake_version=$(apt-cache policy cmake | grep -oP 'Candidate:\s*\K.*')
else
    cmake_version="${arg_versions}"
fi

if ! echo "${all_cmake_versions_available}" | grep -qxF "${cmake_version}"; then
    error "requested version [${cmake_version}] not available. Available versions: [$(echo -e ${all_cmake_versions_available})]"
fi

log "CMake version to be installed: [${cmake_version}]"

# --- installation ---

apt install -qqy --no-install-recommends "cmake=${cmake_version}" \
    || error "installation of cmake [${cmake_version}] failed"

# --- summary ---
cmake_version=$(dpkg-query -W -f='${Version}' cmake)
log "CMake version now installed: [${cmake_version}]"
echo -e "${cmake_version}" # result for the caller

# --- Create aliases ---
arg_alias=$(to_boolean "${arg_alias}")
if [ "$arg_alias" == '' ] ; then
    exit 1;
fi

if [[ "${arg_alias}" == 1 ]]; then
    log "alias: adding aliases for [bash zsh]"
    [[ -f '/etc/bash.bashrc' ]] && echo cmake_version=\'${cmake_version}\' >> /etc/bash.bashrc;
    [[ -f '/etc/zsh/zshrc' ]]   && echo cmake_version=\'${cmake_version}\' >> /etc/zsh/zshrc;
fi

exit 0;
