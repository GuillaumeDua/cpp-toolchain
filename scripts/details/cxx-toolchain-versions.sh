#!/bin/bash
set -uo pipefail

# =============================================================================================
# This file is part of https://github.com/GuillaumeDua/cpp-toolchain
# License: see https://github.com/GuillaumeDua/cpp-toolchain/blob/main/LICENSE
# =============================================================================================

# What a published image carries where a pin cannot say: its distribution point release and
# archive snapshot, its compilers, its standard library implementations and its toolchain
# commands, as `key=value` lines, the shape cxx-stdlibs.sh already reports in.
#
# Runs *inside* an image, over a bind-mounted scripts/ - the published stages carry no checks,
# and these versions are knowable nowhere else: GCC and Clang pin a major and install from
# rolling apt sources, and the standard libraries arrive as dependencies with no ARG at all.
# Every other pin is exact, so collecting it here would restate the Dockerfile.
#
# Usage, from anywhere - the paths resolve against this script:
#     bash cxx-toolchain-versions.sh
#
# It takes no stage: it reports what it finds, so a runtime image answers with standard libraries
# alone and nothing here has to be kept in step with the canonical stage lists.
#
# Keys carry the kind of thing they describe as a prefix - `distribution.`, `compilers.`,
# `libraries.` or `tools.` - because a release note renders each group differently.

this_script_name=$(basename "$0")
this_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# The installers own which majors they put there, and the standard library probe owns how a
# runtime is read out of its ELF. Both are composed, never reimplemented.
install_scripts_dir="${this_script_dir}/../install"
stdlibs_script="${this_script_dir}/../checks/cxx-stdlibs.sh"
c_stdlibs_script="${this_script_dir}/../checks/c-stdlibs.sh"

die() { echo "[${this_script_name}] error: $*" >&2; exit 1; }

# `-dumpfullversion` on GCC, because `-dumpversion` has reported the major alone since GCC 7.
# Clang has no such split. Both answer the upstream version, unlike dpkg, which reports
# `1:22.1.8~++20260613092238+e80beda6e255-1~exp1~...` for the same compiler.
collect_compilers(){
    local driver="$1" version_flag="$2" lister="$3"
    local major version

    [ -r "${install_scripts_dir}/${lister}" ] \
      || die "cannot find ${lister} one level above scripts/details"

    for major in $(bash "${install_scripts_dir}/${lister}" --list-installed 2>/dev/null); do
        version=$("${driver}-${major}" "${version_flag}" 2>/dev/null)
        [ -n "${version}" ] && echo "compilers.${driver}-${major}=${version}"
    done
}

# Keyed by the package that owns each runtime rather than by implementation: the same one can
# appear twice (an llvm-<major> copy beside a multiarch one), and the package is what tells them
# apart and what a reader can install.
# Both ABI fields get keys of their own, because they move independently of the version beside them
# and of each other, and because which one carries the information differs by implementation:
#   libstdc++  abi is the greatest GLIBCXX_ symbol - `GLIBCXX_3.4.32 not found` is what a consumer
#              hits - and cxxabi the greatest CXXABI_ one.
#   libc++     abi is its inline namespace, reported as LIBCPP_ABI_1, which has not moved; cxxabi is
#              the SONAME of libc++abi, the separate library it needs at load time, which does.
#   glibc      abi is the greatest GLIBC_ symbol. It reports no cxxabi, C having no C++ ABI, and a
#              field the probe does not emit is a key that is not written.
# Takes the probe and its arguments, so the C and C++ sides read one loop rather than two copies.
collect_stdlibs(){
    local probe="$1"
    shift

    local row pair package
    local -A field

    [ -r "${probe}" ] \
      || die "cannot find $(basename "${probe}") one level above scripts/details"

    while IFS= read -r row; do
        field=()
        for pair in ${row}; do
            field["${pair%%=*}"]="${pair#*=}"
        done

        package="${field[package]:--}"
        [ "${package}" = '-' ] && continue

        [ "${field[version]:--}" != '-' ] && echo "libraries.${package}=${field[version]}"
        [ "${field[abi]:--}"     != '-' ] && echo "libraries.${package}-abi=${field[abi]}"
        [ "${field[cxxabi]:--}"  != '-' ] && echo "libraries.${package}-cxxabi=${field[cxxabi]}"
    done < <(bash "${probe}" "$@" 2>/dev/null)
}

# The point release, which the pin cannot state: `ubuntu:24.04` is a rolling tag, and VERSION_ID
# restates it, while VERSION carries the `24.04.3` the base image was built from.
# /etc/os-release rather than lsb_release, which needs a package a minimal image has no reason to
# carry. Sourced in a subshell: it sets NAME, VERSION and ID in whatever shell reads it.
collect_distribution(){
    [ -r /etc/os-release ] || return 0
    (
        . /etc/os-release
        [ "${ID:-}" = 'ubuntu' ] && [ -n "${VERSION:-}" ] && echo "distribution.ubuntu=${VERSION%% *}"
    )

    # The snapshot the image installs from, read back out of the sources the Dockerfile rewrote in
    # place. The apt preferences pin it used is dropped right after the realignment; these two files
    # are what survives, so they are where the timestamp can still be confirmed against the note.
    local snapshot
    snapshot=$(grep -hoE 'snapshot\.ubuntu\.com/ubuntu/[0-9A-Z]+' \
                    /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null \
               | sed 's|.*/||' | sort -u | head -n 1)
    [ -n "${snapshot}" ] && echo "distribution.ubuntu-snapshot=${snapshot}"

    return 0
}

# The commands a C++ toolchain reader looks for, which is the matrix in README.md minus the
# editors, the shells and the misc row. A declared list rather than everything on PATH: an image
# carries far more than the toolchain, and only the toolchain belongs in a release note.
# The compiler drivers are not among them: collect_compilers answers for those, from the driver
# itself, which states its release where its package states only what apt called the build.
toolchain_commands=(
    cmake make ninja ccache vcpkg conan bpkg git
    gcov gcov-tool llvm-cov llvm-profdata
    clang-tidy clang-format clangd scan-build lld lldb
    cppcheck include-what-you-use
    doxygen dot lcov genhtml
    valgrind gdb
)

# vcpkg is a symlink into /opt, conan comes from pipx and doxygen is a pre-built binary under
# /usr/local/bin, so dpkg owns none of the three and each has to state its own version. They are
# also the only three of the list carrying a pin, so a value here that disagrees with the pin is a
# finding rather than a surprise.
# TODO: confirm all three invocations against a published image - a version the extraction below
#       cannot find leaves the key unwritten, which reports presence and no version.
declare -A version_flag=(
    [vcpkg]='version'
    [conan]='--version'
    [doxygen]='--version'
)

# The first dotted number a command prints. Loose on purpose: the three callers spell their
# version line three different ways, and the number is the only part they agree on.
version_from_command(){
    local flag="${version_flag[$1]:-}"
    [ -n "${flag}" ] || return 0

    "$1" "${flag}" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1
}

# What each command resolves to, and which package owns it.
#
# The version comes from the owning package rather than from `<command> --version`: a flag table
# spanning the whole list above is that many chances to guess wrong, and a wrong guess reads as an
# absent tool rather than as an error. dpkg answers every apt-installed one the same way.
#
# A command with no unversioned name is looked up under every installed major, so `lld-22` reads
# like the `compilers.clang-22` key beside it. The unversioned name wins where both exist, which
# is what makes a versioned key meaningful: it says no alternative was registered in this image.
collect_tools(){
    local name major path real row package version index
    local -a majors=() names=() paths=() packages=()
    local -A package_of_path=() version_of_package=()

    # Descending, so a host carrying several majors answers with the newest, which is what the
    # unversioned alternative points at where one is registered.
    mapfile -t majors < <({
        bash "${install_scripts_dir}/gcc.sh"  --list-installed 2>/dev/null
        bash "${install_scripts_dir}/llvm.sh" --list-installed 2>/dev/null
    } | sort -n -u -r)

    for name in "${toolchain_commands[@]}"; do
        path=$(command -v "${name}" 2>/dev/null)

        if [ -z "${path}" ]; then
            for major in "${majors[@]}"; do
                path=$(command -v "${name}-${major}" 2>/dev/null)
                [ -n "${path}" ] && { name="${name}-${major}"; break; }
            done
        fi

        [ -n "${path}" ] || continue
        real=$(readlink -f "${path}" 2>/dev/null)
        [ -x "${real}" ] || continue

        names+=("${name}")
        paths+=("${real}")
    done

    [ "${#names[@]}" -gt 0 ] || return 0

    # One dpkg -S for every path, then one dpkg-query for every package. A call per command would
    # be sixty, and dpkg -S walks its whole file list each time.
    # `libc6:amd64: /usr/lib/...` carries an architecture the package name does not.
    if command -v dpkg-query >/dev/null 2>&1; then
        while IFS= read -r row; do
            package="${row%%: *}"
            package="${package%%:*}"
            [ -n "${package}" ] && package_of_path["${row#*: }"]="${package}"
        done < <(dpkg -S "${paths[@]}" 2>/dev/null)

        # Guarded: `printf` over an empty array still prints one empty line, which would reach
        # dpkg-query as an empty package name.
        if [ "${#package_of_path[@]}" -gt 0 ]; then
            mapfile -t packages < <(printf '%s\n' "${package_of_path[@]}" | sort -u)

            while IFS=' ' read -r package version; do
                # Debian versions carry an epoch and a revision around the upstream release.
                version="${version#*:}"
                version_of_package["${package}"]="${version%%[-~]*}"
            done < <(dpkg-query -W -f='${Package} ${Version}\n' "${packages[@]}" 2>/dev/null)
        fi
    fi

    for index in "${!names[@]}"; do
        name="${names[index]}"
        package="${package_of_path[${paths[index]}]:-}"

        version=''
        [ -n "${package}" ] && version="${version_of_package[${package}]:-}"
        [ -n "${version}" ] || version=$(version_from_command "${name}")

        # A command that is here but cannot state its version reports [-], the same marker the
        # checks scripts use: presence is the half of the answer that is always knowable, and it
        # is the half a per-stage inventory is built from.
        echo "tools.${name}=${version:--}"
    done

    return 0
}

[ $# -eq 0 ] || die "usage: ${this_script_name}  (no arguments - it reports what it finds)"

{
    collect_distribution
    collect_compilers gcc   -dumpfullversion gcc.sh
    collect_compilers clang -dumpversion     llvm.sh
    collect_stdlibs "${stdlibs_script}"   --view=library --format=fields
    collect_stdlibs "${c_stdlibs_script}" --format=fields
    collect_tools
} | sort
