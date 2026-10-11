#!/usr/bin/env bash
# scan_repo.sh — clone one repo, restore deleted/dangling git history, scan with
# TruffleHog (verified secrets only), emit a JSON results file, then clean up.
#
# Usage: scan_repo.sh <owner/repo> <output-dir>
set -uo pipefail

REPO_FULL_NAME="${1:?usage: scan_repo.sh <owner/repo> <output-dir>}"
OUT_DIR_RAW="${2:?usage: scan_repo.sh <owner/repo> <output-dir>}"
REPO_SAFE_NAME=$(echo "$REPO_FULL_NAME" | tr '/' '_')
WORK_DIR=$(mktemp -d)

# Resolve OUT_DIR to an ABSOLUTE path now, before we `cd` into the cloned
# repo below — a relative path like "results" would otherwise be looked up
# relative to the clone's directory later and silently fail to be found.
mkdir -p "$OUT_DIR_RAW"
OUT_DIR=$(cd "$OUT_DIR_RAW" && pwd)
RESULT_FILE="$OUT_DIR/${REPO_SAFE_NAME}.json"
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
# Preserve the original directory structure (under a per-commit folder)
# instead of flattening the path into one filename — a flattened name from
# a deeply nested repo (e.g. Unity asset trees) can exceed the 255-byte
# filename limit and fail with "File name too long". We still guard against
# that per-component limit by hashing any path that's still too long.
mkdir -p __restored_deleted
git rev-list --all 2>/dev/null | while read -r commit; do
    parent=$(git log --pretty=format:"%P" -n 1 "$commit" 2>/dev/null | awk '{print $1}')
    [[ -z "$parent" ]] && continue
    short_commit="${commit:0:12}"
    git diff --name-status "$parent" "$commit" 2>/dev/null | while IFS=$'\t' read -r status file; do
        [[ "$status" != "D" ]] && continue
        [[ -z "$file" ]] && continue

        dest="__restored_deleted/${short_commit}/${file}"

        # Fall back to a hashed filename if the destination path (or any
        # single component of it) would be too long for the filesystem.
        if [[ ${#dest} -gt 240 ]] || [[ -n $(echo "$file" | awk -F'/' '{for(i=1;i<=NF;i++) if(length($i)>240) print "x"}') ]]; then
            hash=$(echo -n "$file" | sha1sum | cut -d' ' -f1)
            ext="${file##*.}"
            [[ "$ext" == "$file" ]] && ext="bin"
            dest="__restored_deleted/${short_commit}/_long_${hash}.${ext}"
            echo "${dest} <= ${file}" >> __restored_deleted/_long_paths.log
        fi

        mkdir -p "$(dirname "$dest")" 2>/dev/null
        git show "${parent}:${file}" > "$dest" 2>/dev/null
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
# Each finding is tagged with where it was found:
#   current_file     - still present in the latest tracked snapshot (HEAD) --
#                       i.e. it's live in the repo today, not something that
#                       was deleted and only recoverable via history.
#   restored_deleted  - only recovered by restoring a file git rm'd earlier.
#   dangling_blob     - only recovered from an unreachable/dangling git object.
#   git_internal      - found inside .git/ itself (e.g. an unpacked loose
#                       object) rather than under our own restore folders.
python3 - "$REPO_FULL_NAME" "$WORK_DIR/raw_findings.jsonl" "$RESULT_FILE" "$WORK_DIR/repo" <<'PYEOF'
import json, sys, subprocess, os

repo, raw_path, out_path, repo_dir = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
findings = []

def classify(abs_path: str) -> str:
    rel = os.path.relpath(abs_path, repo_dir)
    if rel.startswith("__restored_deleted" + os.sep) or rel == "__restored_deleted":
        return "restored_deleted"
    if rel.startswith("__dangling_blobs" + os.sep) or rel == "__dangling_blobs":
        return "dangling_blob"
    if rel.startswith(".git" + os.sep) or rel == ".git":
        return "git_internal"
    return "current_file"

def is_tracked_at_head(abs_path: str) -> bool:
    rel = os.path.relpath(abs_path, repo_dir)
    try:
        result = subprocess.run(
            ["git", "-C", repo_dir, "ls-files", "--error-unmatch", "--", rel],
            capture_output=True, text=True, timeout=10,
        )
        return result.returncode == 0
    except Exception:
        return False

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
            abs_file = (obj.get("SourceMetadata", {})
                           .get("Data", {})
                           .get("Filesystem", {})
                           .get("file", "unknown"))
            source = classify(abs_file) if abs_file != "unknown" else "unknown"
            rel_file = os.path.relpath(abs_file, repo_dir) if abs_file != "unknown" else "unknown"
            findings.append({
                "detector": obj.get("DetectorName", "unknown"),
                "file": rel_file,
                "source": source,
                # True only when the secret is in a file currently tracked
                # on HEAD (i.e. still live in the repo today, not just
                # recovered from deleted/dangling history) -- a strong
                # signal it's a known/intentional fixture rather than a
                # leak someone tried to scrub.
                "currently_live_on_head": is_tracked_at_head(abs_file) if source == "current_file" else False,
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
