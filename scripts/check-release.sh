#!/bin/bash
# scripts/check-release.sh - The release step: refuse a release whose wt.sh
# VERSION constant differs from the latest release tag. Read-only; `--help`
# carries the usage and exit codes.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/utils.sh"
source "$SCRIPT_DIR/../lib/version.sh"

# Print usage and exit codes
show_help() {
    cat <<'EOF'
check-release.sh - confirm wt.sh's VERSION matches the latest release tag

Run it after tagging a release and before pushing the tag.

Usage:
    check-release.sh [<repo-dir>]

    <repo-dir>  the checkout to check; defaults to the one holding this script

Exit codes:
    0  VERSION matches the latest v* tag reachable from HEAD
    1  VERSION and that tag differ — bump VERSION or tag the release
    2  no v* tag is reachable, <repo-dir> is not a git repository, or
       wt.sh has no VERSION="x.y.z" line
EOF
}

# Compare the VERSION constant with the latest release tag and report
# Args: $1 repo directory (optional)
# Out: the verdict line; errors on stderr
# Side: exits 0, 1 or 2 per show_help
main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        show_help
        exit 0
    fi

    local repo_dir="${1:-$(cd -P "$SCRIPT_DIR/.." && pwd)}"

    if ! command_exists git || ! version_git "$repo_dir" rev-parse --git-dir >/dev/null 2>&1; then
        echo "error: $repo_dir is not a git repository, or git is missing" >&2
        exit 2
    fi

    local constant
    constant=$(read_version_constant "$repo_dir/wt.sh" 2>/dev/null) || constant=""
    if [[ -z "$constant" ]]; then
        echo "error: no VERSION=\"x.y.z\" line in $repo_dir/wt.sh" >&2
        exit 2
    fi

    local tag
    tag=$(version_git "$repo_dir" describe --tags --abbrev=0 \
        --match "$WT_RELEASE_TAG_GLOB" HEAD 2>/dev/null) || tag=""
    if [[ -z "$tag" ]]; then
        echo "error: no v* tag reachable from HEAD in $repo_dir" >&2
        exit 2
    fi

    if [[ "$constant" != "${tag#v}" ]]; then
        echo "error: VERSION \"$constant\" in wt.sh differs from tag $tag — bump VERSION or tag the release" >&2
        exit 1
    fi

    echo "ok: VERSION $constant matches tag $tag"
}

main "$@"
