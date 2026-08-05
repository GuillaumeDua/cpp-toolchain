#!/usr/bin/env bash
#
# Asserts that a built image really contains what it advertises: the pinned versions the release
# manifest lists, and the tools the README package matrix promises for the stage.
#
# Runs inside a `check-<stage>` build stage that inherits the published stage, so:
#   - the expectations are the Dockerfile's own ARGs, collected into /expected.env by the
#     `check-expectations` stage. There is no second source of truth, and bumping a pin needs no
#     edit here;
#   - what it inspects is the published filesystem, after every purge, autoremove and dist-upgrade;
#   - the layers are already in the builder's cache, so this costs one exec rather than an image
#     load or a registry pull.
#
# Restricted to what the leanest stage ships: bash, coreutils, ldconfig, dpkg-query.
# `runtime` has no python3 and no jq.
#
# Every violation is reported before the script fails - a partial list turns one CI round-trip
# into several. A failing assertion is a finding about the image, not a test to loosen.
#
# Usage: bash check-image.sh <stage>

# No `-e`: assertions have to keep running after one fails.
# No `pipefail` either - `cmd | head -n 1` closes the pipe early and would report a working tool
# as broken.
set -u

readonly stage="${1:?usage: check-image.sh <stage>}"

# The pins, written by the `check-expectations` stage from the Dockerfile's ARGs.
#   Read from a file rather than declared as ARGs in each of the five check stages, so that there is
#   one place listing what gets checked. Absent when the script is run by hand against an image, in
#   which case the environment supplies the same names.
if [ -f /expected.env ]; then
    # shellcheck source=/dev/null
    . /expected.env
fi

case "${stage}" in
    runtime | build | static-analysis | documentation | dev) ;;
    *)  printf 'check-image: unknown stage [%s]\n' "${stage}" >&2
        exit 2 ;;
esac

failures=0
ok()  { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; failures=$((failures + 1)); }

# An ARG that arrives here empty makes every assertion built on it pass vacuously, which is the
# failure mode a version-checking suite hides best. Refuse to run rather than report a false green.
require() {
    local name
    for name in "$@"; do
        if [ -z "${!name:-}" ]; then
            printf 'check-image: %s is empty - add `ARG %s` to the check-expectations stage\n' \
                "${name}" "${name}" >&2
            exit 2
        fi
    done
}

# --- assertions ---------------------------------------------------------------------------------

# first_line <command...> - the command's first line of output; fails when it does not run.
first_line() {
    local output
    output="$("$@" 2>&1)" || return 1
    printf '%s' "${output%%$'\n'*}"
}

# version_is <label> <expected> <command...>
#   Compares the first dotted-numeric token of the output as a whole token rather than a substring,
#   so an image carrying 4.4.10 does not satisfy an expectation of 4.4.0.
version_is() {
    local label="$1" want="$2"; shift 2
    local line found
    if ! line="$(first_line "$@")"; then
        bad "${label}: [$*] did not run"
        return
    fi
    found="$(grep -oE '[0-9]+(\.[0-9]+)+' <<< "${line}" | head -n 1)"
    if [ "${found}" = "${want}" ]
    then ok "${label} ${found}"
    else bad "${label}: expected ${want}, got [${line}]"
    fi
}

# on_path <tool>... - resolvable against the image's own PATH, which is what `RUN` inherits.
on_path() {
    local tool
    for tool in "$@"; do
        if command -v "${tool}" > /dev/null 2>&1
        then ok "${tool}"
        else bad "${tool} is not on PATH"
        fi
    done
}

# not_on_path <tool>... - the negatives that define a stage boundary.
not_on_path() {
    local tool
    for tool in "$@"; do
        if command -v "${tool}" > /dev/null 2>&1
        then bad "${tool} is on PATH and should not be, in ${stage}"
        else ok "no ${tool}"
        fi
    done
}

# installed <package>... - dpkg state, deliberately not a filesystem test.
#   Debian multiarch ships /usr/bin/x86_64-linux-gnu-g++ in every image as an alias for the native
#   compiler, so `test -x` on a cross driver passes in a lean image that has no cross toolchain.
#   dpkg is also the only thing that can answer here: every apt block in the Dockerfile ends with
#   `rm -rf /var/lib/apt/lists/*`, so no published image can serve an apt-cache query.
installed() {
    local package state
    for package in "$@"; do
        state="$(dpkg-query -W -f='${db:Status-Status}' -- "${package}" 2> /dev/null)"
        if [ "${state}" = 'installed' ]
        then ok "${package}"
        else bad "${package} is not installed"
        fi
    done
}

# resolves <soname>... - present in the dynamic linker's cache.
resolves() {
    local soname
    for soname in "$@"; do
        if ldconfig -p | grep -qF "${soname}"
        then ok "${soname}"
        else bad "${soname} does not resolve"
        fi
    done
}

# stage_has <stage>... - whether the stage under check is one of them.
stage_has() {
    local candidate
    for candidate in "$@"; do
        if [ "${candidate}" = "${stage}" ]; then
            return 0
        fi
    done
    return 1
}

# selector_majors <selector> - the bare-numeric tokens of a GCC_VERSIONS / LLVM_VERSIONS value.
#   Only those name a major that must be installed. The other accepted forms - `>=13`, `all`,
#   `latest`, `latest-stable` - are resolved against the archive during the build, so the Dockerfile
#   does not know which majors they produced and this script must not pretend it does.
selector_majors() {
    local token
    for token in $1; do
        if [[ "${token}" =~ ^[0-9]+$ ]]; then
            printf '%s\n' "${token}"
        fi
    done
    return 0
}

# highest_major <selector> - the greatest bare-numeric token, empty when the selector is dynamic.
highest_major() {
    local token highest=''
    for token in $(selector_majors "$1"); do
        if [ -z "${highest}" ] || [ "${token}" -gt "${highest}" ]; then
            highest="${token}"
        fi
    done
    printf '%s' "${highest}"
}

# compiler_family <driver> <selector>
#   Every explicitly requested major must be installed and report itself, and the unversioned driver
#   must resolve to the highest requested one - a broken update-alternatives registration is the
#   failure nothing else here would notice.
#
#   Both gcc.sh and llvm.sh register each version at a priority equal to its own major, so highest
#   wins in either family and the rule is the same for g++ and clang++.
#
#   Never asserts that a major is absent: Ubuntu 24.04's own g++-13 arrives through ordinary
#   transitive dependencies even at GCC_VERSIONS=15.
compiler_family() {
    local driver="$1" selector="$2"
    local major found highest
    local requested=()

    for major in $(selector_majors "${selector}"); do
        requested+=("${major}")
        found="$("${driver}-${major}" -dumpversion 2> /dev/null)"
        found="${found%%.*}"
        if [ "${found}" = "${major}" ]
        then ok "${driver}-${major}"
        else bad "${driver}-${major}: reports major [${found:-absent}]"
        fi
    done

    found="$("${driver}" -dumpversion 2> /dev/null)"
    found="${found%%.*}"
    if [ -z "${found}" ]; then
        bad "${driver} is not on PATH"
        return
    fi
    if [ "${#requested[@]}" -eq 0 ]; then
        ok "${driver} ${found} (selector [${selector}] resolves against the archive)"
        return
    fi

    highest="$(highest_major "${selector}")"
    if [ "${found}" = "${highest}" ]
    then ok "${driver} -> ${found}"
    else bad "${driver} resolves to major ${found}, expected ${highest} (update-alternatives priority)"
    fi
}

# --- what every stage must hold -----------------------------------------------------------------

printf 'check-image: %s\n' "${stage}"

require BASE_IMAGE UBUNTU_SNAPSHOT GCC_VERSIONS

# ubuntu:24.04@sha256:... -> 24.04
ubuntu_tag="${BASE_IMAGE#*:}"
ubuntu_tag="${ubuntu_tag%%@*}"
if grep -qx "VERSION_ID=\"${ubuntu_tag}\"" /etc/os-release
then ok "ubuntu ${ubuntu_tag}"
else bad "ubuntu: /etc/os-release does not report ${ubuntu_tag}"
fi

apt_sources=(/etc/apt/sources.list.d)
if [ -f /etc/apt/sources.list ]; then
    apt_sources+=(/etc/apt/sources.list)
fi
if grep -rqF "snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT}" "${apt_sources[@]}"
then ok "apt snapshot ${UBUNTU_SNAPSHOT}"
else bad "apt sources are not pinned to snapshot ${UBUNTU_SNAPSHOT}"
fi

# The C++ runtime libraries. `runtime` installs them and immediately runs
# `apt-get purge -y --auto-remove gnupg software-properties-common`, which makes them the packages
# most exposed to the drift this script exists to catch.
installed libc6 libgcc-s1 libstdc++6

# libstdc++6 comes from ppa:ubuntu-toolchain-r/test, and the snapshot pin is dropped in `runtime`
# specifically so the PPA can win. If that ordering ever regresses the library falls back to the
# Ubuntu archive build - GCC 14 on 24.04 - and every binary the pinned GCC produces fails to load.
#   `>=` rather than `=`: the PPA ships the newest libstdc++ it has, which can be ahead of the
#   requested compiler. At least as new as the compiler is the property that has to hold.
gcc_highest="$(highest_major "${GCC_VERSIONS}")"
if [ -n "${gcc_highest}" ]; then
    libstdcxx="$(dpkg-query -W -f='${Version}' -- libstdc++6 2> /dev/null)"
    if [ "${libstdcxx%%.*}" -ge "${gcc_highest}" ] 2> /dev/null
    then ok "libstdc++6 ${libstdcxx} >= GCC ${gcc_highest}"
    else bad "libstdc++6 is [${libstdcxx:-absent}], older than the pinned GCC ${gcc_highest} - the toolchain PPA did not win in runtime"
    fi
fi

# --- runtime ------------------------------------------------------------------------------------

if stage_has runtime; then
    # The deploy image stays minimal.
    not_on_path gcc g++ clang clang++ cmake git make

    resolves libstdc++.so.6 libgcc_s.so.1 libc.so.6

    # libstdc++ only is the documented runtime contract (README package matrix), even though `build`
    # can link against libc++: llvm.sh's `all` package set installs libc++-<N>-dev there.
    #   Closing that gap would mean registering apt.llvm.org in the minimal deploy image and
    #   interacting with the snapshot realignment - a design decision. Asserted here so that it stays
    #   a decision rather than drifting in unnoticed.
    if ldconfig -p | grep -qF 'libc++.so.1'
    then bad 'libc++.so.1 is in runtime - the documented contract is libstdc++ only'
    else ok 'no libc++.so.1 (libstdc++-only contract)'
    fi
fi

# --- build, and everything built on it ------------------------------------------------------------

if stage_has build static-analysis documentation dev; then
    require LLVM_VERSIONS CMAKE_VERSION VCPKG_VERSION CONAN_VERSION

    version_is cmake "${CMAKE_VERSION}" cmake --version
    version_is vcpkg "${VCPKG_VERSION}" vcpkg --version
    version_is conan "${CONAN_VERSION}" conan --version

    compiler_family g++     "${GCC_VERSIONS}"
    compiler_family clang++ "${LLVM_VERSIONS}"

    on_path gcc g++ clang clang++ cmake ctest cpack make ninja ccache git pkg-config gcov python3
    installed libc6-dev

    if [ -x /opt/vcpkg/vcpkg ]
    then ok '/opt/vcpkg/vcpkg'
    else bad '/opt/vcpkg/vcpkg is missing'
    fi

    # binutils.sh installs each requested target best-effort, and its skip path is a `log` call that
    # is a no-op under --silent=yes: a -cross image that cross-compiles nothing builds green and
    # silent today.
    #   BINUTILS_TARGETS spells triplets the Debian way (x86-64-linux-gnu), which is also dpkg's
    #   spelling, so checking the package needs none of the underscore/hyphen normalisation that
    #   matching /usr/bin/x86_64-linux-gnu-g++ would.
    for target in ${BINUTILS_TARGETS:-}; do
        installed "g++-${target}"
    done
fi

if stage_has build; then
    # The build / static-analysis boundary is update-alternatives, not packages: llvm.sh runs the
    # upstream apt.llvm.org script with the `all` package set regardless of --minimalistic, so
    # clang-tidy-<major> is physically here. What --minimalistic changes is which alternatives get
    # registered, and that is what the stage contract actually promises.
    for major in $(selector_majors "${LLVM_VERSIONS}"); do
        installed "clang-tidy-${major}"
    done
    not_on_path clang-tidy clang-format clangd scan-build lldb llvm-cov llvm-profdata
fi

# --- the LLVM tooling, per stage ------------------------------------------------------------------

# documentation re-runs llvm.sh with --coverage, which registers the coverage alternatives only.
if stage_has static-analysis documentation dev; then
    on_path llvm-cov llvm-profdata
fi

if stage_has static-analysis dev; then
    on_path clang-tidy clang-format clangd clang-check clang-query scan-build lldb llvm-symbolizer \
            cppcheck include-what-you-use
fi

# --- documentation --------------------------------------------------------------------------------

if stage_has documentation dev; then
    require DOXYGEN_RELEASE
    on_path doxygen dot lcov genhtml

    # doxygen.sh installs the upstream pre-built binary on amd64 and falls back to the distro apt
    # package elsewhere, where the pin is not honoured (README, "On host architecture").
    if [ "$(dpkg --print-architecture)" = 'amd64' ]; then
        doxygen_version="${DOXYGEN_RELEASE#Release_}"
        version_is doxygen "${doxygen_version//_/.}" doxygen --version
    fi
fi

# --- dev --------------------------------------------------------------------------------------

if stage_has dev; then
    require OHMYZSH_COMMIT
    on_path gdb valgrind svn emacs nano vim jq rg docker-compose bash zsh

    # oh-my-zsh is pinned by commit: the repository publishes no tags at all.
    ohmyzsh="$(git -C "${HOME:-/root}/.oh-my-zsh" rev-parse HEAD 2> /dev/null)"
    if [ "${ohmyzsh}" = "${OHMYZSH_COMMIT}" ]
    then ok "oh-my-zsh ${ohmyzsh}"
    else bad "oh-my-zsh is at [${ohmyzsh:-absent}], expected ${OHMYZSH_COMMIT}"
    fi

    # powerlevel10k is cloned --depth 1 --branch, so the checkout keeps no tag to read the version
    # back from. Its presence and its wiring into .zshrc are all that is observable from here.
    if [ -d "${HOME:-/root}/.oh-my-zsh/custom/themes/powerlevel10k" ]
    then ok 'powerlevel10k theme'
    else bad 'powerlevel10k theme directory is missing'
    fi
    if grep -qF 'powerlevel10k/powerlevel10k' "${HOME:-/root}/.zshrc"
    then ok '.zshrc selects powerlevel10k'
    else bad '.zshrc does not select the powerlevel10k theme'
    fi
fi

# --- verdict --------------------------------------------------------------------------------------

if [ "${failures}" -ne 0 ]; then
    printf '\ncheck-image: %s - %d failed assertion(s).\n' "${stage}" "${failures}" >&2
    printf 'The image does not contain what it advertises. That is a finding, not a test to loosen.\n' >&2
    exit 1
fi

printf '\ncheck-image: %s - every assertion holds.\n' "${stage}"
