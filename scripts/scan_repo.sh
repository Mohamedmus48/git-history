#!/usr/bin/env bash
# scan_repo.sh — clone one repo, restore deleted/dangling git history, scan with
# TruffleHog (verified secrets only), emit a JSON results file, then clean up.
#
# Usage: scan_repo.sh <owner/repo> <output-dir>
set -uo pipefail

REPO_FULL_NAME="${1:?usage: scan_repo.sh <owner/repo> <output-dir>}"
OUT_DIR="${2:?usage: scan_repo.sh <owner/repo> <output-dir>}"
REPO_SAFE_NAME=$(echo "$REPO_FULL_NAME" | tr '/' '_')
WORK_DIR=$(mktemp -d)
RESULT_FILE="$OUT_DIR/${REPO_SAFE_NAME}.json"

mkdir -p "$OUT_DIR"
echo "::group::📦 $REPO_FULL_NAME"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# --- 1. Clone (full history, single branch is NOT used — we need all refs) ---
if ! git clone --quiet "https://github.com/${REPO_FULL_NAME}.git" "$WORK_DIR/repo" 2>/tmp/clone_err.log; then
    echo "⚠️  Clone failed for $REPO_FULL_NAME, skipping"
    cat /tmp/clone_err.log
    echo '{"repo":"'"$REPO_FULL_NAME"'","status":"clone_failed","findings":[]}' > "$RESULT_FILE"
    echo "::endgroup::"
    exit 0
fi

cd "$WORK_DIR/repo"

# --- 2. Restore deleted files from commit history (parent/child diff) -------
mkdir -p __restored_deleted
git rev-list --all 2>/dev/null | while read -r commit; do
    parent=$(git log --pretty=format:"%P" -n 1 "$commit" 2>/dev/null | awk '{print $1}')
    [[ -z "$parent" ]] && continue
    git diff --name-status "$parent" "$commit" 2>/dev/null | while read -r status file; do
        [[ "$status" != "D" ]] && continue
        safe_name=$(echo "$file" | tr '/' '_')
        git show "${parent}:${file}" > "__restored_deleted/${commit:0:12}___${safe_name}" 2>/dev/null
    done
done

# --- 3. Unpack any .pack files so trufflehog sees loose objects too --------
for pack in .git/objects/pack/pack-*.pack; do
    [[ -f "$pack" ]] || continue
    git unpack-objects -q < "$pack" 2>/dev/null
done

# --- 4. Pull out dangling/unreachable blobs ---------------------------------
mkdir -p __dangling_blobs
git fsck --unreachable --dangling --no-reflogs --full 2>/dev/null \
    | awk '/unreachable blob/ {print $3}' \
    | while read -r h; do
        git cat-file -p "$h" > "__dangling_blobs/${h}.blob" 2>/dev/null
    done

# --- 5. Run TruffleHog, verified secrets only -------------------------------
if command -v trufflehog >/dev/null 2>&1; then
    trufflehog filesystem --only-verified --json --no-update "$WORK_DIR/repo" \
        > "$WORK_DIR/raw_findings.jsonl" 2>/tmp/trufflehog_err.log || true
else
    echo "⚠️  trufflehog not found on PATH" >&2
    : > "$WORK_DIR/raw_findings.jsonl"
fi

# --- 6. Normalize findings into one JSON array for this repo ---------------
python3 - "$REPO_FULL_NAME" "$WORK_DIR/raw_findings.jsonl" "$RESULT_FILE" <<'PYEOF'
import json, sys

repo, raw_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
findings = []

try:
    with open(raw_path, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            findings.append({
                "detector": obj.get("DetectorName", "unknown"),
                "file": (obj.get("SourceMetadata", {})
                            .get("Data", {})
                            .get("Filesystem", {})
                            .get("file", "unknown")),
                "verified": obj.get("Verified", False),
                "raw_snippet_redacted": "***redacted***",
            })
except FileNotFoundError:
    pass

with open(out_path, "w") as f:
    json.dump({
        "repo": repo,
        "status": "scanned",
        "finding_count": len(findings),
        "findings": findings,
    }, f, indent=2)
PYEOF

echo "✅ $REPO_FULL_NAME scanned — $(python3 -c "import json;print(json.load(open('$RESULT_FILE'))['finding_count'])") verified finding(s)"
echo "::endgroup::"
