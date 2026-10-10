#!/bin/bash
set -uo pipefail

# See docs/IMAGES_VALIDATION.md

this_script_name=$(basename "$0")

# The helpers shared with the other scripts. Not composed standalone, unlike scripts/checks/*.sh:
# this one only ever runs inside a validate stage, which copies scripts/ whole.
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/../../lib/shared.sh"

# The link groups the installers register: gcc.sh owns `gcc`, llvm.sh owns `clang`.
# Both are present from `build` up, so a stage that has a compiler has both.
toolchain_link_groups=(gcc clang)

# The paths a group manages: its master `Link:` and one per entry of the `Slaves:` block that
# follows it. `--query` prints a second `Slaves:` block per alternative, listing targets rather
# than links, so the scan stops at the `Status:` line that closes the header.
managed_links(){
    update-alternatives --query "$1" 2>/dev/null \
      | awk '/^Status:/      { exit }
             /^Link: /       { print $2 }
             /^Slaves:/      { in_slaves = 1; next }
             in_slaves       { print $2 }'
}

# A link group only decides what a command resolves to while the link is still its own.
# update-alternatives records the group in its database and never looks at the path again, so a
# package that ships that path has dpkg overwrite the symlink with no warning and no conflict:
# `--display` keeps reporting the alternative it selected while the command answers for whatever
# the package brought. That is invisible to the origin check, which reads package names.
check_group(){
    local group="$1"
    local links link target

    links=$(managed_links "${group}")
    if [ -z "${links}" ]; then
        fail "[${group}] no alternatives link group in this image - nothing registered it"
        return
    fi

    while read -r link; do
        [ -n "${link}" ] || continue

        if [ ! -e "${link}" ] && [ ! -L "${link}" ]; then
            fail "[${group}] [${link}] is registered but absent - the command the group names is not in this image"
            continue
        fi

        if [ ! -L "${link}" ]; then
            fail "[${group}] [${link}] is a file rather than a symlink - a package shipped its own copy over the alternative"
            continue
        fi

        target=$(readlink "${link}")
        case "${target}" in
            /etc/alternatives/* ) pass "[${group}] [${link}] -> [$(readlink -f "${link}")]" ;;
            * ) fail "[${group}] [${link}] points at [${target}] rather than through /etc/alternatives - a package replaced the alternative" ;;
        esac
    done <<< "${links}"
}

for group in "${toolchain_link_groups[@]}"; do
    check_group "${group}"
done

finish 'toolchain command' 'in this image' 'every toolchain command resolves through the alternative its installer registered'
