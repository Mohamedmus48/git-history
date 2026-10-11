#!/usr/bin/env bash
# list_repos.sh — list all public repo full names for an org/user.
#
# By default this includes forks and archived repos too: companies often
# publish customized forks of third-party tools, or leave old projects
# archived — both can still contain leaked secrets in their history, so we
# don't silently drop them. Set EXCLUDE_FORKS=1 / EXCLUDE_ARCHIVED=1 in the
# environment to opt back into filtering.
set -uo pipefail

ORG="${1:?usage: list_repos.sh <org-login> [max-repos]}"
MAX_REPOS="${2:-200}"

ARGS=(repo list "$ORG" -L "$MAX_REPOS" --json nameWithOwner,isPrivate,isFork,isArchived)

[[ "${EXCLUDE_FORKS:-0}" == "1" ]] && ARGS+=(--source)
[[ "${EXCLUDE_ARCHIVED:-0}" == "1" ]] && ARGS+=(--no-archived)

echo "ℹ️  running: gh ${ARGS[*]}" >&2

RAW_JSON=$(gh "${ARGS[@]}" 2>/tmp/list_repos_err.log)
STATUS=$?

if [[ $STATUS -ne 0 ]]; then
    echo "❌ gh repo list failed for org '$ORG':" >&2
    cat /tmp/list_repos_err.log >&2
    exit 1
fi

TOTAL=$(echo "$RAW_JSON" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)
echo "ℹ️  gh returned $TOTAL repo(s) total (before filtering private) for '$ORG'" >&2

echo "$RAW_JSON" | python3 -c '
import json, sys
repos = json.load(sys.stdin)
for r in repos:
    if not r.get("isPrivate", False):
        print(r["nameWithOwner"])
'

if [[ "$TOTAL" -eq 0 ]]; then
    echo "⚠️  No repos returned at all for '$ORG'. Possible causes: the org/user login is wrong, it has no public repos, or it requires a different casing/slug. Try passing the exact GitHub org login directly as the company_name input." >&2
fi
