#!/bin/bash

set -eu

# =============================================================================================
# This file is part of https://github.com/GuillaumeDua/CppShelf
# License: see https://github.com/GuillaumeDua/CppShelf/blob/main/LICENSE
#
# libc++ scope: every --mode installs the host libc++ (libc++-<N>-dev / libc++abi-<N>-dev / libunwind-<N>-dev),
#   so native `clang++ -stdlib=libc++` works without GCC - see the package set note further down.
#   Cross-target libc++ (libc++ built for another arch) is NOT bundled: it has no portable apt package and requires an
#   LLVM `runtimes` source build (future scripts/libcxx.sh). See binutils.sh for the cross scope.
# =============================================================================================

this_script_name=$(basename "$0")

arg_versions='latest-stable'
arg_list=0
arg_silent=1
arg_alias=0
arg_mode='full'
arg_cleanup=0

internal_script_path='impl.sh'

help(){
    echo "Usage: ${this_script_name}" 1>&2
    echo "
    Boolean values: y|yes|1|true or n|no|0|false (case insensitive)

        [ -l | --list ]         : Only list available versions, expanding [versions].       Boolean -> default is [0]
        [ -v | --versions ]     : Versions to install.                                      String: all|latest|latest-stable|>=(number)|(space-separated-numbers...) -> default is [latest-stable]
            - [all]             : all versions availables                                       Ex: 'all'
            - [latest]          : only the latest        version available                      Ex: 'latest'
            - [latest-stable]   : only the latest-stable version available                      Ex: 'latest-stable'
            - [>=(number)]      : all versions greater or equal to <number>                     Ex: '>=42'
            - [numbers...]      : only listed versions.                                         Ex: '13 25 42' (space-separated)
        [ -s | --silent ]       : Run in silent mod.                                        Boolean -> default is [1]
        [ -a | --alias]         : Set bash/zsh-rc aliases.                                  Boolean -> default is [0]
        [ --mode ]              : How much of the toolchain to install.                     String: minimalistic|coverage|full -> default is [full]
            - [minimalistic]    : the compilers and their runtimes, no tools
            - [coverage]        : minimalistic + the coverage tools (llvm-cov, llvm-profdata)
            - [full]            : the whole toolchain (clang-tidy, clang-format, clangd, lldb, scan-build, ...)
        [ -c | --cleanup]       : purge any (pre-)existing llvm/clang package installation: Boolean -> default is [0]
        [ -h | --help ]         : Display usage/help

    For instance, to only install the two latest versions available, use:
        sudo ./${this_script_name} --versions=\"\$(sudo ./${this_script_name} --list --versions='all' | tail -2)\"
        " 1>&2
    exit 0
}
clean(){
    if [ -f "${internal_script_path}" ]; then
        rm -rf "${internal_script_path}"
    fi
}
error(){
    echo -e "[${this_script_name}]: $@" >> /dev/stderr
    clean; exit 1
}
warning(){
    echo -e "[${this_script_name}]: $@" >> /dev/stderr
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

options_short=s:,v:,a:,c,l,h
options_long=silent:,versions:,alias:,mode:,cleanup,help,list
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
    --mode )
        arg_mode="$2"
        shift 2
        ;;
    -c | --cleanup )
        arg_cleanup=1
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

case "${arg_mode}" in
    minimalistic | coverage | full ) ;;
    * ) error "invalid --mode=[${arg_mode}] - expected one of: minimalistic, coverage, full" ;;
esac

arg_cleanup=$(to_boolean "${arg_cleanup}")
if [ "$arg_cleanup" == '' ] ; then
    exit 1;
fi

log "arguments - versions:          [${arg_versions}]"
log "arguments - silent:            [${arg_silent}]"
log "arguments - alias:             [${arg_alias}]"
log "arguments - list:              [${arg_list}]"
log "arguments - mode:              [${arg_mode}]"
log "arguments - cleanup:           [${arg_cleanup}]"

# --- fetch llvm.sh ---
# or use:
#   sudo add-apt-repository "deb http://apt.llvm.org/$(lsb_release -cs)/ llvm-toolchain-$(lsb_release -cs) main"
#   wget https://apt.llvm.org/llvm-snapshot.gpg.key
#   sudo apt-key add llvm-snapshot.gpg.key

if [ -f "${internal_script_path}" ]; then
    echo -e "temporary file [${internal_script_path}] already exists" >> /dev/stderr # not using error to avoid deleting the file
    exit 1
fi

external_script_url='https://apt.llvm.org/llvm.sh'

# wget -O - https://apt.llvm.org/llvm-snapshot.gpg.key | sudo apt-key add -
# wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | sudo tee /etc/apt/trusted.gpg.d/apt.llvm.org.asc
# NO_PUBKEY 1A127079A92F09ED
# REFACTO: remove gpg key -> already added by ${external_script_url}
wget -qO - https://apt.llvm.org/llvm-snapshot.gpg.key | sudo gpg --dearmor --batch --yes -o /etc/apt/trusted.gpg.d/llvm-snapshot.gpg \
    && wget -qO ${internal_script_path} ${external_script_url} \
    && chmod +x "${internal_script_path}"
if [ $? != 0 ] || [ ! -f "${internal_script_path}" ]; then
    error "fetching [${external_script_url}] failed"
fi

# --- list versions ---

llvm_version_to_install_regex='^LLVM_VERSION_PATTERNS\[(\d+)\]=\"\-\K(\d+)'
list_to_install_llvm_versions(){
    grep -oP $llvm_version_to_install_regex ${internal_script_path} | uniq | sort -n
}
llvm_version_installed_regex='^clang-\K([0-9]{2})'
list_installed_llvm_versions(){
    dpkg -l | grep ^ii |  awk '{print $2}' | grep -oP $llvm_version_installed_regex | uniq | sort -n
}

# --- which versions ---
llvm_latest_stable=$(grep -oP '^CURRENT_LLVM_STABLE=\K(\d+)' ${internal_script_path})
all_llvm_versions_available=$(list_to_install_llvm_versions)

if [ "$arg_versions" = 'all' ]; then
    llvm_versions=$all_llvm_versions_available
elif [ "$arg_versions" = 'latest-stable' ]; then
    llvm_versions=$llvm_latest_stable
elif [ "$arg_versions" = 'latest' ]; then
    llvm_versions=$(echo ${all_llvm_versions_available} | tr " " "\n" | tail -1)
elif [[ "$arg_versions" =~  ^\>=[0-9]+$ ]]; then
    from_version=$(echo "${arg_versions}" | grep -oP '^>=\K([0-9])+$')
    log "using user-provided rule: >=[$from_version]"
    if [ -z "$from_version" ]; then
        error "invalid version='>=[0-9]+' value"
    fi
    llvm_versions=$(echo "$all_llvm_versions_available" | awk "\$1 >= ${from_version}")
elif [[ "$arg_versions" =~  ^[0-9]+( [0-9]+)*$ ]]; then
    log "using user-provided version(s) list: [${arg_versions}]"
    llvm_versions="${arg_versions}"
elif [ ! -z "$arg_versions" ]; then
    error "invalid value for argument version [${arg_versions}]"
fi

if [ -z "$llvm_versions" ]; then
    log "empty versions range, nothing to do"
    echo -e "$(list_installed_llvm_versions)" # result for the caller
    clean; exit 0
fi
if [[ ! $(echo -n $llvm_versions) =~  ^[0-9]+( [0-9]+)*$ ]]; then
    error "invalid versions range: [$llvm_versions]"
fi

## --- list mod ? ---
if [[ ${arg_list} == 1 ]]; then
    echo -e "${llvm_versions}"
    clean; exit 0
fi

log "LLVM version(s) to be installed: [${llvm_versions}]"

# --- clean update-alternatives ---
sudo rm -rf /etc/alternatives/clang* /etc/alternatives/llvm-symbolizer /etc/alternatives/lldb
sudo rm -rf /var/lib/dpkg/alternatives/clang* /var/lib/dpkg/alternatives/llvm-symbolizer /var/lib/dpkg/alternatives/lldb

# --- installations ---

# for version in "${llvm_versions_to_install[@]}"; do
#     add-apt-repository -y \
#         "deb http://apt.llvm.org/$(lsb_release -cs)/ llvm-toolchain-$(lsb_release -cs)-${version}" main   \
#         > /dev/null                                         \
#     || error "adding apt-repository for [${version}] failed"
# done
# apt update -qqy

# quick-fix: Ubuntu-24.04-noble not fully supported yet, switching to Ubuntu-22.04-jammy
codename=$(lsb_release -cs)
# if [ "${codename}" = "noble" ]; then
#     warning "codename=[${codename}] is not supported yet, switching to [jammy]"
#     codename="jammy"
# fi

if [[ ${arg_cleanup} == 1 ]]; then
    sudo apt-get remove -y "llvm-*"
    sudo apt-get remove -y "lldb-*"
    sudo apt-get remove -y "clang-*"
    sudo apt-get remove -y "python3-lldb-*"
fi

# --- package set, per mode ---
#
# The upstream installer takes one optional `all` argument, and it is all-or-nothing:
#   without it   -> clang-<N> lldb-<N> lld-<N> clangd-<N>
#   with it      -> the above, plus clang-tidy, clang-format, clang-tools (scan-build), llvm-<N>-dev,
#                   llvm-<N>-tools, libclang-*-dev, liblldb-<N>-dev, and the runtimes below.
# So anything between the two has to be named here.
#
# What every mode keeps beyond the default set are the compiler's own runtimes - the libc++ stack,
# the sanitizers, OpenMP and Polly. Those are compiler capabilities rather than tools: dropping them
# would silently break `-stdlib=libc++`, `-fsanitize=...`, `-fopenmp` and `-mllvm -polly` for anyone
# using a minimalistic install, which is not what "only clang/clang++, not tools" promises.
upstream_package_set=''
if [[ "${arg_mode}" == 'full' ]]; then
    upstream_package_set='all'
fi

# compiler_runtimes_for <version> - the runtime packages the upstream default set omits.
compiler_runtimes_for(){
    local version="$1"
    local packages="libc++-${version}-dev libc++abi-${version}-dev libunwind-${version}-dev libomp-${version}-dev"
    # Same guard as upstream: these two are only published from LLVM 15 onwards.
    if [ "${version}" -gt 14 ]; then
        packages="${packages} libclang-rt-${version}-dev libpolly-${version}-dev"
    fi
    echo "${packages}"
}

mapfile -t llvm_versions_to_install < <(echo -n "$llvm_versions")
for version in "${llvm_versions_to_install[@]}"; do

    # fix potential conflicts:
    #   sudo apt-get purge --auto-remove llvm python3-lldb-14 llvm-14 -y; \

    # yes '' |
    ./${internal_script_path} ${version} ${upstream_package_set} -n ${codename} > /dev/null 2>&1 \
    || error "running [${external_script_url} ${version} ${upstream_package_set}] failed"

    # `full` already has everything through `all`; the other two have to add what they need.
    #   llvm-<N> is where llvm-cov and llvm-profdata live - `all` only pulls it in transitively,
    #   through llvm-<N>-dev.
    extra_packages=''
    case "${arg_mode}" in
        minimalistic ) extra_packages="$(compiler_runtimes_for ${version})" ;;
        coverage )     extra_packages="$(compiler_runtimes_for ${version}) llvm-${version}" ;;
    esac
    if [ -n "${extra_packages}" ]; then
        # The upstream installer has just run `apt-get update`, so the lists are populated here.
        sudo apt-get install -qqy --no-install-recommends ${extra_packages} > /dev/null 2>&1 \
        || error "installing [${extra_packages}] failed"
    fi

    # Warning: only one installation of `lldb` is allowed by `apt` at a time. Cannot use `--no-remove` here
    # apt install -qq -y --no-install-recommends \
    #     clang-format-${version} \
    #     clang-tidy-${version}   \
    #     lldb-${version}         \
    # || error "installation of [${version}] (tools) failed"
    # clang and clang-tools

    update_alternative_priority="${version}"

    if [[ "${arg_mode}" == 'minimalistic' ]]; then
        update-alternatives --quiet                                                                                             \
            --install /usr/bin/clang clang /usr/bin/clang-${version} ${update_alternative_priority}                             \
            --slave /usr/bin/clang++                  clang++                   /usr/bin/clang++-${version}                     \
        || error "update-alternatives of [${version}] failed"
    elif [[ "${arg_mode}" == 'coverage' ]]; then
        update-alternatives --quiet                                                                                             \
            --install /usr/bin/clang clang /usr/bin/clang-${version} ${update_alternative_priority}                             \
            --slave /usr/bin/clang++                  clang++                   /usr/bin/clang++-${version}                     \
            --slave /usr/bin/llvm-cov                 llvm-cov                  /usr/bin/llvm-cov-${version}                     \
            --slave /usr/bin/llvm-profdata            llvm-profdata             /usr/bin/llvm-profdata-${version}                \
        || error "update-alternatives of [${version}] failed"
    else
        update-alternatives --quiet                                                                                             \
            --install /usr/bin/clang clang /usr/bin/clang-${version} ${update_alternative_priority}                             \
            --slave /usr/bin/clang++                  clang++                   /usr/bin/clang++-${version}                     \
            --slave /usr/bin/clang-format             clang-format              /usr/bin/clang-format-${version}                \
            --slave /usr/bin/clang-tidy               clang-tidy                /usr/bin/clang-tidy-${version}                  \
            --slave /usr/bin/clangd                   clangd                    /usr/bin/clangd-${version}                      \
            --slave /usr/bin/clang-check              clang-check               /usr/bin/clang-check-${version}                 \
            --slave /usr/bin/clang-query              clang-query               /usr/bin/clang-query-${version}                 \
            --slave /usr/bin/clang-apply-replacements clang-apply-replacements  /usr/bin/clang-apply-replacements-${version}    \
            --slave /usr/bin/llvm-cov                 llvm-cov                  /usr/bin/llvm-cov-${version}                     \
            --slave /usr/bin/llvm-profdata            llvm-profdata             /usr/bin/llvm-profdata-${version}                \
            --slave /usr/bin/sancov                   sancov                    /usr/bin/sancov-${version}                      \
            --slave /usr/bin/scan-build               scan-build                /usr/bin/scan-build-${version}                  \
            --slave /usr/bin/scan-view                scan-view                 /usr/bin/scan-view-${version}                   \
            --slave /usr/bin/llvm-symbolizer          llvm-symbolizer           /usr/bin/llvm-symbolizer-${version}             \
            --slave /usr/bin/lldb                     lldb                      /usr/bin/lldb-${version}                        \
        || error "update-alternatives of [${version}] failed"
    fi

done
clean;

# --- summary ---
llvm_versions=$(list_installed_llvm_versions)
log "LLVM versions now detected: [$(echo -e $(list_installed_llvm_versions))]" 
echo -e "${llvm_versions}" # result for the caller

# --- Create aliases ---
arg_alias=$(to_boolean "${arg_alias}")
if [ "$arg_alias" == '' ] ; then
    exit 1;
fi

if [[ "${arg_alias}" == 1 ]]; then
    log "alias: adding aliases for [bash zsh]"
    [[ -f '/etc/bash.bashrc' ]] && echo llvm_versions=\'${llvm_versions}\' >> /etc/bash.bashrc;
    [[ -f '/etc/zsh/zshrc' ]]   && echo llvm_versions=\'${llvm_versions}\' >> /etc/zsh/zshrc;
fi

exit 0;

# Legacy inline integration
#
# ARG llvm_versions=all
# RUN apt install -y wget bash \
#     && wget -O - https://apt.llvm.org/llvm-snapshot.gpg.key | sudo apt-key add - \
#     && wget https://apt.llvm.org/llvm.sh \  
#     && chmod +x llvm.sh \
#     && llvm_versions=${llvm_versions:=$(cat llvm.sh | grep -oP 'LLVM_VERSION_PATTERNS\[(\d+)\]=\"\-\K(\d+)' | sort -n)} \
#     \
#     echo "[toolchain] Embedding llvm versions = [${llvm_versions}]";    \
#     echo llvm_versions=\'${llvm_versions}\' >> /etc/bash.bashrc;        \
#     # \'' fix coloration in vscode with docker extension ¯\_(ツ)_/¯
#     echo llvm_versions=\'${llvm_versions}\' >> /etc/zsh/zshrc;          \
#     # \'' fix coloration in vscode with docker extension ¯\_(ツ)_/¯
#     \
#     && (yes '' | ./llvm.sh $llvm_versions) \
#     && echo $llvm_versions | tr " " "\n" | xargs -I {} sh -c '          \
#         update-alternatives                                                                 \
#             --install /usr/bin/clang clang /usr/bin/clang-{} {}                             \
#             --slave /usr/bin/clang++         clang++         /usr/bin/clang++-{}            \
#             --slave /usr/bin/clang-format    clang-format    /usr/bin/clang-format-{}       \
#             --slave /usr/bin/clang-tidy      clang-tidy      /usr/bin/clang-tidy-{}         \
#             --slave /usr/bin/clangd          clangd          /usr/bin/clangd-{}             \
#             --slave /usr/bin/llvm-symbolizer llvm-symbolizer /usr/bin/llvm-symbolizer-{}    \
#             --slave /usr/bin/lldb            lldb            /usr/bin/lldb-{}               \
#     '
