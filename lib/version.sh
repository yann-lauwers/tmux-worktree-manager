#!/bin/bash
# lib/version.sh - The version wt reports: the install checkout's nearest
# release tag, else the VERSION constant declared in wt.sh

# Release tags are v-prefixed semver; a tag outside this glob never names a version.
WT_RELEASE_TAG_GLOB='v[0-9]*'

# Run git against a directory with the caller's repository overrides cleared,
# so an exported GIT_DIR (a git hook, a wrapper) cannot redirect it elsewhere.
# Args: $1 directory, $2... git arguments
# Out: git's stdout
version_git() {
    local dir="$1"
    shift
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR git -C "$dir" "$@"
}

# Read the VERSION constant a wt.sh declares, in its one accepted form VERSION="x.y.z"
# Args: $1 path to wt.sh
# Out: x.y.z, or nothing when the line is missing or malformed
read_version_constant() {
    sed -n 's/^VERSION="\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)"$/\1/p' "$1"
}

# Resolve the version for the install checkout at $1: `git describe` against its
# release tags, or the VERSION constant where $1 holds no .git entry, git is
# absent, or describe fails. A .git file (a linked worktree) counts as a checkout.
# Args: $1 install directory
# Out: the version, without a leading "v" (2.1.0, 2.1.0-3-gabc1234, …-dirty, a bare hash)
resolve_version() {
    local dir="$1"
    local described=""

    if [[ -e "$dir/.git" ]] && command_exists git; then
        described=$(version_git "$dir" describe --tags --always --dirty \
            --match "$WT_RELEASE_TAG_GLOB" 2>/dev/null) || described=""
    fi

    if [[ -n "$described" ]]; then
        echo "${described#v}"
    else
        echo "$VERSION"
    fi
}
