#!/bin/bash
# scripts/shellcheck.sh - The one shellcheck invocation CI and the pre-push
# hook both run: reads the release pinned in ci.yml, refuses on a missing or
# mismatched shellcheck, then lints the whole command/library surface at
# severity info and above, and exits with shellcheck's own status. The
# severity floor is set here, on the invocation, rather than in .shellcheckrc
# — shellcheck's rc file format takes no severity key.

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/lib/utils.sh"

# Print usage and exit codes
show_help() {
    cat <<'EOF'
shellcheck.sh - lint the wt command/library surface with the pinned shellcheck release

Usage:
    shellcheck.sh [--help]

Exit codes:
    0  no shellcheck finding, at severity info and above
    1  shellcheck is missing, or reports a release other than the one ci.yml pins
    -  otherwise, shellcheck's own exit code from the lint run
EOF
}

# Read the shellcheck release pinned in .github/workflows/ci.yml — the same
# value CI installs and CONTRIBUTING.md names.
# Out: the pinned release, e.g. v0.x.y
pinned_shellcheck_version() {
    yq '.env.SHELLCHECK_VERSION' "$REPO_ROOT/.github/workflows/ci.yml"
}

# Refuse, naming the pinned release and where to get it, when shellcheck is
# missing from PATH or reports a release other than $1.
# Args: $1 pinned release (e.g. v0.x.y)
# Side: exits 1 on refusal
require_pinned_shellcheck() {
    local pinned="$1"
    local bare="${pinned#v}"

    if ! command_exists shellcheck; then
        echo "shellcheck.sh: shellcheck is not on PATH — install $pinned from https://github.com/koalaman/shellcheck/releases/tag/$pinned (see CONTRIBUTING.md § Prerequisites)" >&2
        exit 1
    fi

    local actual
    actual="$(shellcheck --version)"
    if [[ "$actual" != *"version: $bare"* ]]; then
        echo "shellcheck.sh: expected shellcheck $pinned, found $(command -v shellcheck) reporting:" >&2
        echo "$actual" >&2
        echo "install $pinned from https://github.com/koalaman/shellcheck/releases/tag/$pinned (see CONTRIBUTING.md § Prerequisites)" >&2
        exit 1
    fi
}

# Refuse on a missing/mismatched shellcheck, else lint the whole
# command/library surface at severity info and above, exiting with the
# lint run's own status.
main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        show_help
        exit 0
    fi

    local pinned
    pinned="$(pinned_shellcheck_version)"
    require_pinned_shellcheck "$pinned"

    cd "$REPO_ROOT"
    shellcheck -x -S info wt.sh lib/*.sh commands/*.sh completions/wt.bash install.sh
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    main "$@"
fi
