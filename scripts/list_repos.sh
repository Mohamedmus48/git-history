#!/usr/bin/env bash
# list_repos.sh — list all public, non-archived repo full names for an org/user.
set -euo pipefail

ORG="${1:?usage: list_repos.sh <org-login> [max-repos]}"
MAX_REPOS="${2:-200}"

gh repo list "$ORG" \
    -L "$MAX_REPOS" \
    --source \
    --no-archived \
    --json nameWithOwner,isPrivate,isFork \
    --jq '.[] | select(.isPrivate == false) | .nameWithOwner'
