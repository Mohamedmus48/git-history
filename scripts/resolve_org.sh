#!/usr/bin/env bash
# resolve_org.sh — given a company name, try to find its most likely GitHub org/user login.
set -euo pipefail

COMPANY_NAME="${1:?usage: resolve_org.sh <company name>}"

echo "🔎 Resolving GitHub org for: $COMPANY_NAME" >&2

# 1) If the caller already passed something that looks like a valid org login
#    (letters, digits, hyphens, no spaces), try it directly first.
CANDIDATE_SLUG=$(echo "$COMPANY_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' )

try_login() {
    local login="$1"
    if gh api "users/$login" --jq '.login' >/dev/null 2>&1; then
        echo "$login"
        return 0
    fi
    return 1
}

if [[ -n "$CANDIDATE_SLUG" ]] && try_login "$CANDIDATE_SLUG"; then
    exit 0
fi

# 2) Fall back to GitHub's search API for users/orgs matching the free-text name.
RESULT=$(gh api -X GET search/users \
    -f q="$COMPANY_NAME in:login,name type:org" \
    --jq '.items[0].login' 2>/dev/null || true)

if [[ -n "$RESULT" && "$RESULT" != "null" ]]; then
    echo "$RESULT"
    exit 0
fi

# 3) Last resort: broaden the search to users as well (some companies publish
#    under a personal/user account rather than an org).
RESULT=$(gh api -X GET search/users \
    -f q="$COMPANY_NAME in:login,name" \
    --jq '.items[0].login' 2>/dev/null || true)

if [[ -n "$RESULT" && "$RESULT" != "null" ]]; then
    echo "$RESULT"
    exit 0
fi

echo "❌ Could not resolve a GitHub org/user for '$COMPANY_NAME'" >&2
exit 1
