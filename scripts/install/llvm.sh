#!/bin/bash

set -eu

# =============================================================================================
# This file is part of https://github.com/GuillaumeDua/cpp-toolchain
# License: see https://github.com/GuillaumeDua/cpp-toolchain/blob/main/LICENSE
#
# libc++ scope: every compiler --mode installs the host libc++ (libc++-<N>-dev / libc++abi-<N>-dev / libunwind-<N>-dev),
#   so native `clang++ -stdlib=libc++` works without GCC - see the package set note further down.
#
#   `--mode=runtime` is the other half of that:
#       the shared libraries alone, no compiler and no headers,
#       for an image whose job is to run what such a toolchain produced.
#
#   WARNING: Cross-target libc++ (libc++ built for another arch) is NOT bundled:
#       it has no portable apt package and requires an LLVM `runtimes` source build (future scripts/libcxx.sh).
#       See binutils.sh for the cross scope.
# =============================================================================================

this_script_name=$(basename "$0")

arg_versions='latest-stable'
arg_versions_explicit=0
arg_list_available=0
arg_list_installed=0
arg_silent=1
arg_alias=0
arg_mode='full'
arg_cleanup=0

internal_script_path='impl.sh'
gpg_key_path='llvm-snapshot.gpg.key'
gpg_key_installed_path='/etc/apt/trusted.gpg.d/llvm-snapshot.gpg'

# How many times a network-facing step is attempted
max_attempts=3

# The last of max_attempts has to land after the throttling window.
retry_backoff_seconds=30

help(){
    echo "Usage: ${this_script_name}" 1>&2
    echo "
    Boolean values: y|yes|1|true or n|no|0|false (case insensitive)

        [ -l | --list-available ]: Only list available versions, expanding [versions].  Boolean -> default is [0]
        [ --list-installed ]     : Only list the major versions already installed.      Boolean -> default is [0]
                                   Filtered by [versions] when given explicitly, otherwise every installed major is listed.
        [ -v | --versions ]      : Versions to install.                                 String: all|latest|latest-stable|>=(number)|(space-separated-numbers...) -> default is [latest-stable]
            - [all]              : all versions availables                                  Ex: 'all'
            - [latest]           : only the latest        version available                 Ex: 'latest'
            - [latest-stable]    : only the latest-stable version available                 Ex: 'latest-stable'
            - [>=(number)]       : all versions greater or equal to <number>                Ex: '>=42'
            - [numbers...]       : only listed versions.                                    Ex: '13 25 42' (space-separated)
        [ -s | --silent ]        : Run in silent mod.                                    Boolean -> default is [1]
        [ -a | --alias]          : Set bash/zsh-rc aliases.                              Boolean -> default is [0]
        [ --mode ]               : How much of the toolchain to install.                 String: runtime|minimalistic|coverage|full -> default is [full]
            - [runtime]          : the libc++ runtime alone (libc++1, libc++abi1) - no compiler, no headers.
                                   For an image that runs what another one built. LLVM 20 and later.
            - [minimalistic]     : the compilers and their runtimes, no tools
            - [coverage]         : minimalistic + the coverage tools (llvm-cov, llvm-profdata)
            - [full]             : the whole toolchain (clang-tidy, clang-format, clangd, lldb, scan-build, ...)
        [ -c | --cleanup]        : purge any (pre-)existing llvm/clang package installation: Boolean -> default is [0]
        [ -h | --help ]          : Display usage/help

    For instance, to only install the two latest versions available, use:
        sudo ./${this_script_name} --versions=\"\$(sudo ./${this_script_name} --list-available --versions='all' | tail -2)\"
        " 1>&2
    exit 0
}
clean(){
    rm -f "${internal_script_path}" "${gpg_key_path}"
}
error_diagnosis(){
    local sources addresses
    sources=$(grep -rl 'apt\.llvm\.org' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | paste -sd' ' -)
    # A connection failure does not name the address it tried.
    addresses=$(timeout 5 getent ahosts apt.llvm.org 2>/dev/null | awk '{print $1}' | sort -u | paste -sd' ' -)
    {
        echo -e "[${this_script_name}]: diagnosis helper:"
        if command -v lsb_release >/dev/null 2>&1; then
            echo -e "\t- distribution:        [$(lsb_release -ds 2>/dev/null)]"
        fi
        echo -e "\t- apt codename:        [${codename:-<unresolved>}]"
        echo -e "\t- mode:                [${arg_mode}]"
        echo -e "\t- versions requested:  [${arg_versions}]"
        echo -e "\t- apt.llvm.org source: [${sources:-<none registered>}]"
        echo -e "\t- apt.llvm.org hosts:  [${addresses:-<unresolved>}]"
    } >> /dev/stderr
}
error(){
    echo -e "[${this_script_name}]: $@" >> /dev/stderr
    error_diagnosis
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
# apt.llvm.org throttles a host that requests too much too fast, for up to a minute at a time.
# Every step retried here is idempotent, and only the last attempt reports.
run_with_retries(){
    local attempts="$1" what="$2"; shift 2
    local attempt=1

    while [ "${attempt}" -lt "${attempts}" ]; do
        "$@" > /dev/null 2>&1 && return 0
        warning "${what} failed - retrying in $(( attempt * retry_backoff_seconds ))s (attempt $(( attempt + 1 ))/${attempts})"
        sleep $(( attempt * retry_backoff_seconds ))
        attempt=$(( attempt + 1 ))
    done
    run "${what}" "$@"
}
to_boolean(){
    if [[ $# != 1 ]]; then
        error "$0: missing argument"
    fi
    case "$1" in
        [Yy]|[Yy][Ee][Ss]|1|[Tt][Rr][Uu][Ee]) echo 1;;
        [Nn]|[Nn][Oo]|0|[Ff][Aa][Ll][Ss][Ee]) echo 0;;
        *)
            error "to_boolean: invalid conversion from [$1] to boolean"
            ;;
    esac
}

# --- options management ---

options_short=s:,v:,a:,c,l,h
options_long=silent:,versions:,alias:,mode:,cleanup,help,list-available,list-installed
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
    --mode )
        arg_mode="$2"
        shift 2
        ;;
    -c | --cleanup )
        arg_cleanup=1
        shift;
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

arg_list_available=$(to_boolean "${arg_list_available}")

arg_list_installed=$(to_boolean "${arg_list_installed}")

case "${arg_mode}" in
    runtime | minimalistic | coverage | full ) ;;
    * ) error "invalid --mode=[${arg_mode}] - expected one of: runtime, minimalistic, coverage, full" ;;
esac

arg_cleanup=$(to_boolean "${arg_cleanup}")

log "arguments - versions:          [${arg_versions}]"
log "arguments - silent:            [${arg_silent}]"
log "arguments - alias:             [${arg_alias}]"
log "arguments - list-available:    [${arg_list_available}]"
log "arguments - mode:              [${arg_mode}]"
log "arguments - cleanup:           [${arg_cleanup}]"

# --- list installed versions ---
#   Answered from dpkg alone, ahead of everything below:
#   the fetch writes a GPG key into /etc/apt/trusted.gpg.d, and a query must not touch
#   what it is asked about.
llvm_version_installed_regex='^clang-\K[0-9]+(?=(:.*)?$)'
list_installed_llvm_versions(){
    dpkg -l | grep ^ii | awk '{print $2}' | grep -oP "${llvm_version_installed_regex}" | sort -n -u
}

# Filter a set of majors by a --versions selector.
#   This reports what is present rather than what could be installed, so an explicit list is intersected with the set rather than passed through.
#   latest-stable is refused here: only the upstream index defines it, and fetching that is exactly what this query must not do.
select_versions(){
    local selector="$1"
    local versions="$2"

    case "${selector}" in
        all )
            echo "${versions}" ;;
        latest )
            echo "${versions}" | tail -1 ;;
        latest-stable )
            error "--list-installed cannot resolve [latest-stable] without the upstream index - use --versions=latest or --versions=all" ;;
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
    installed_versions=$(list_installed_llvm_versions)
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
fi

# --- fetch llvm.sh ---

for temporary in "${internal_script_path}" "${gpg_key_path}"; do
    if [ -f "${temporary}" ]; then
        echo -e "temporary file [${temporary}] already exists" >> /dev/stderr # not using error to avoid deleting the file
        exit 1
    fi
done

codename=$(lsb_release -cs)

apt_llvm_base_url='https://apt.llvm.org'
external_script_url="${apt_llvm_base_url}/llvm.sh"
gpg_key_url="${apt_llvm_base_url}/llvm-snapshot.gpg.key"

# wget's own --tries exhausts all three attempts within about three seconds, well inside a throttling window,
# which is why run_with_retries wraps it below rather than being replaced by it.
wget_options=(--no-verbose --tries=${max_attempts} --retry-connrefused --timeout=30)

# REFACTO: drop this block - the upstream installer at ${external_script_url} installs the same key,
#   and an image layered on another one inherits the key its base installed.
# The fetch is not piped into gpg: without pipefail, a failed download would surface as a malformed key.
# Installed unconditionally, never skipped on the file being present: gpg --dearmor creates its output
#   before writing it, so an interrupted run leaves a truncated key that a presence check reads as installed,
#   and every later apt-get update then fails with NO_PUBKEY until someone removes it by hand.
run_with_retries "${max_attempts}" "fetching the signing key [${gpg_key_url}]" \
    wget "${wget_options[@]}" -O "${gpg_key_path}" "${gpg_key_url}" \
|| error "fetching the signing key [${gpg_key_url}] failed"

run "installing the signing key" \
    gpg --dearmor --batch --yes -o "${gpg_key_installed_path}" "${gpg_key_path}" \
|| error "installing the signing key fetched from [${gpg_key_url}] failed"

run_with_retries "${max_attempts}" "fetching [${external_script_url}]" \
    wget "${wget_options[@]}" -O "${internal_script_path}" "${external_script_url}" \
|| error "fetching [${external_script_url}] failed"

[ -f "${internal_script_path}" ] || error "fetching [${external_script_url}] produced no file"
chmod +x "${internal_script_path}"

# --- list versions ---

llvm_version_to_install_regex='^LLVM_VERSION_PATTERNS\[(\d+)\]=\"\-\K(\d+)'
list_to_install_llvm_versions(){
    grep -oP $llvm_version_to_install_regex ${internal_script_path} | uniq | sort -n
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
if [[ ${arg_list_available} == 1 ]]; then
    echo -e "${llvm_versions}"
    clean; exit 0
fi

log "LLVM version(s) to be installed: [${llvm_versions}]"

# --- clean update-alternatives ---
#   Skipped for `runtime`: it registers no alternative, so it has nothing to reset,
#   and a mode that installs no compiler has no business deleting another one's links.
if [[ "${arg_mode}" != 'runtime' ]]; then
    rm -rf /etc/alternatives/clang* /etc/alternatives/llvm-symbolizer /etc/alternatives/lldb
    rm -rf /var/lib/dpkg/alternatives/clang* /var/lib/dpkg/alternatives/llvm-symbolizer /var/lib/dpkg/alternatives/lldb
fi

# --- installations ---

if [[ ${arg_cleanup} == 1 ]]; then
    # Best-effort: matching nothing is the normal case.
    for pattern in 'llvm-*' 'lldb-*' 'clang-*' 'python3-lldb-*'; do
        run "purging [${pattern}]" apt-get remove -y "${pattern}" \
        || warning "purging [${pattern}] found nothing to remove"
    done
fi

# --- package set, per mode ---
#
# The upstream installer takes one optional `all` argument, and it is all-or-nothing:
#   without it   -> clang-<N> lldb-<N> lld-<N> clangd-<N>
#   with it      -> the above, plus clang-tidy, clang-format, clang-tools (scan-build), llvm-<N>-dev,
#                   llvm-<N>-tools, libclang-*-dev, liblldb-<N>-dev, and the runtimes below.
# So anything between the two has to be named here.
#
# What every mode keeps beyond the default set are the compiler's own runtimes - the libc++ stack, the sanitizers, OpenMP and Polly.
# Those are compiler capabilities rather than tools: dropping them would silently break
# `-stdlib=libc++`, `-fsanitize=...`, `-fopenmp` and `-mllvm -polly` even on a minimalistic install.
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

# TODO: re-check the version floor below against what apt.llvm.org currently publishes.
#
# require_runtime_capable_version <version> - the majors `--mode=runtime` can name packages for.
#   From LLVM 20 up, apt.llvm.org publishes these two without a major: libc++1, libc++abi1.
#   Below it they carry one, and not uniformly:
#   - libc++1-18 and libc++1-19
#   - but libc++1-17t64, across the time_t transition.
#
#   Guessing which a given major wants is how a silent mis-install happens, so anything below 20 is refused by name.
#
#   Separate from the function below rather than a guard inside it:
#       `error` there would run in the command substitution that reads the function,
#       exiting that subshell rather than this script, and only `set -e` would then stop the caller.
require_runtime_capable_version(){
    [ "$1" -gt 19 ] \
      || error "--mode=runtime needs LLVM 20 or later: below it apt.llvm.org carries the major in these package names (libc++1-$1), and this script will not guess the spelling"
}

# runtime_libraries_for - the shared libraries alone, for `--mode=runtime`.
#   Which release they hold is decided by the repository suite, not by the package name,
#   which is why this takes no version while compiler_runtimes_for above does.
#   libunwind is deliberately absent: apt.llvm.org builds libc++abi against libgcc_s,
#   which every Debian-derived image already carries, so nothing here would ever load it.
runtime_libraries_for(){
    echo 'libc++1 libc++abi1'
}

# The apt.llvm.org repository, registered here rather than by the upstream installer.
#   `--mode=runtime` must not run that installer at all - it installs clang -
#   so this is the one place the wrapper stops delegating and has to stay in step with upstream by hand.
#
#   Mirrors REPO_NAME in https://apt.llvm.org/llvm.sh:
#       deb ${BASE_URL}/${CODENAME}/ llvm-toolchain${LINKNAME}${LLVM_VERSION_STRING} main
#   LLVM_VERSION_STRING is '-<major>' for every published major but one:
#       the development version is served from the suite with no suffix.
#   Which major that is, is read out of the installer rather than assumed,
#   the same way the available versions and CURRENT_LLVM_STABLE already are.
add_apt_llvm_repository(){
    local version="$1"
    local unversioned suffix="-$1"

    unversioned=$(grep -oP '^LLVM_VERSION_PATTERNS\[\K[0-9]+(?=\]="")' "${internal_script_path}")
    [ "${version}" != "${unversioned}" ] || suffix=''

    run_with_retries "${max_attempts}" "adding the apt.llvm.org repository for [${version}]" \
        add-apt-repository -y "deb ${apt_llvm_base_url}/${codename}/ llvm-toolchain-${codename}${suffix} main" \
    || error "adding the apt.llvm.org repository for [${version}] failed"
}

registered_alternatives=()
mapfile -t llvm_versions_to_install < <(echo -n "$llvm_versions")
for version in "${llvm_versions_to_install[@]}"; do

    # `runtime` stops here: the upstream installer's smallest package set still starts with clang-<N>,
    # so it is skipped entirely and only the repository it would have registered is kept.
    if [[ "${arg_mode}" == 'runtime' ]]; then
        require_runtime_capable_version "${version}"
        runtime_packages="$(runtime_libraries_for)"
        log "installing the libc++ runtime for [${version}]: [${runtime_packages}]"
        add_apt_llvm_repository "${version}"
        run_with_retries "${max_attempts}" "refreshing the apt index" \
            apt-get update -q -y -o Acquire::Retries=${max_attempts} \
        || error "refreshing the apt index failed"
        run_with_retries "${max_attempts}" "installing [${runtime_packages}]" \
            apt-get install -q -y --no-install-recommends -o Acquire::Retries=${max_attempts} ${runtime_packages} \
        || error "installing [${runtime_packages}] failed"
        continue
    fi

    run_with_retries "${max_attempts}" "running [${external_script_url} ${version} ${upstream_package_set}]" \
        ./${internal_script_path} ${version} ${upstream_package_set} -n ${codename} \
    || error "running [${external_script_url} ${version} ${upstream_package_set}] failed"

    # `full` already has everything through `all`; the other two have to add what they need.
    #   llvm-<N> is where llvm-cov and llvm-profdata live - `all` only pulls it in transitively, through llvm-<N>-dev.
    extra_packages=''
    case "${arg_mode}" in
        minimalistic ) extra_packages="$(compiler_runtimes_for ${version})" ;;
        coverage )     extra_packages="$(compiler_runtimes_for ${version}) llvm-${version}" ;;
    esac
    if [ -n "${extra_packages}" ]; then
        # The upstream installer has just run `apt-get update`, so the lists are populated here.
        run_with_retries "${max_attempts}" "installing [${extra_packages}]" \
            apt-get install -q -y --no-install-recommends -o Acquire::Retries=${max_attempts} ${extra_packages} \
        || error "installing [${extra_packages}] failed"
    fi

    # WARNING: apt holds one `lldb` at a time, so installing a second major removes the first,
    #   and the `lldb` slave registered below then points at a binary the earlier major no longer has.
    #   `--no-remove` cannot be used to prevent it.
    update_alternative_priority="${version}"

    # Every slave has the same shape, /usr/bin/<name> -> /usr/bin/<name>-<version>,
    # so a mode only names the tools it registers.
    alternatives_slaves=('clang++')
    case "${arg_mode}" in
        minimalistic ) ;;
        coverage )     alternatives_slaves+=('llvm-cov' 'llvm-profdata') ;;
        * )            alternatives_slaves+=('clang-format' 'clang-tidy' 'clangd' 'clang-check'  \
                                             'clang-query' 'clang-apply-replacements'            \
                                             'llvm-cov' 'llvm-profdata' 'sancov'                 \
                                             'scan-build' 'scan-view' 'llvm-symbolizer' 'lldb') ;;
    esac

    alternatives_arguments=()
    for slave in "${alternatives_slaves[@]}"; do
        alternatives_arguments+=(--slave "/usr/bin/${slave}" "${slave}" "/usr/bin/${slave}-${version}")
        registered_alternatives+=("${slave} ${version}")
    done

    update-alternatives --quiet                                                                     \
        --install /usr/bin/clang clang "/usr/bin/clang-${version}" "${update_alternative_priority}"  \
        "${alternatives_arguments[@]}"                                                              \
    || error "update-alternatives of [${version}] failed"

done

# `update-alternatives --install` accepts a slave whose target does not exist, so a tool renamed or dropped upstream registers as a link the image then ships dangling.
# Checked once every version is in, not per version: the lldb warning above is a link that only the next major invalidates.
dangling=''
for registered in ${registered_alternatives[@]+"${registered_alternatives[@]}"}; do
    slave="${registered%% *}"
    slave_version="${registered##* }"
    [ -e "/usr/bin/${slave}-${slave_version}" ] || dangling+=" /usr/bin/${slave} -> /usr/bin/${slave}-${slave_version}"
done
[ -z "${dangling}" ] || error "update-alternatives registered links whose target does not exist:${dangling}"

clean;

# --- summary ---
llvm_versions=$(list_installed_llvm_versions)
log "LLVM versions now detected: [$(echo -e $(list_installed_llvm_versions))]" 
echo -e "${llvm_versions}" # result for the caller

# --- Create aliases ---
arg_alias=$(to_boolean "${arg_alias}")

if [[ "${arg_alias}" == 1 ]]; then
    log "alias: adding aliases for [bash zsh]"
    [[ -f '/etc/bash.bashrc' ]] && echo llvm_versions=\'${llvm_versions}\' >> /etc/bash.bashrc;
    [[ -f '/etc/zsh/zshrc' ]]   && echo llvm_versions=\'${llvm_versions}\' >> /etc/zsh/zshrc;
fi

exit 0;
