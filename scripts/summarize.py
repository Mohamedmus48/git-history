#!/usr/bin/env python3
"""
summarize.py — merge all per-repo JSON result files into one smart summary:
  - results/summary.json   (machine-readable, full merged results)
  - results/summary.md     (human-readable, written to the Job Summary)
"""
import json
import sys
from pathlib import Path
from collections import defaultdict

SOURCE_LABEL = {
    "restored_deleted": "🕳️ restored deleted file",
    "dangling_blob": "🕳️ dangling/unreachable blob",
    "git_internal": "🕳️ unpacked git object",
    "current_file": "📄 current file",
    "unknown": "❓ unknown",
}

def priority_for(finding: dict) -> str:
    """
    Findings recovered only from history (deleted files, dangling blobs,
    unpacked git objects) are higher priority: someone tried to remove the
    secret, which is a strong signal it's real and still unrevoked.

    Findings still sitting in a file that's currently tracked on HEAD are
    lower priority by default -- it's just as likely to be a long-standing,
    openly-published test fixture (a throwaway CI SSH key, a public demo
    API token, etc.) as it is an active leak nobody has noticed. Still
    worth a quick look, just not an automatic "go report this".
    """
    source = finding.get("source", "unknown")
    if source == "current_file" and finding.get("currently_live_on_head"):
        return "low"
    return "high"

def main():
    if len(sys.argv) != 3:
        print("usage: summarize.py <results-dir> <company-name>", file=sys.stderr)
        sys.exit(1)

    results_dir = Path(sys.argv[1])
    company = sys.argv[2]

    files = sorted(results_dir.glob("*.json"))
    all_repos = []
    for f in files:
        try:
            all_repos.append(json.loads(f.read_text()))
        except Exception:
            continue

    total_repos = len(all_repos)
    scanned = [r for r in all_repos if r.get("status") == "scanned"]
    failed = [r for r in all_repos if r.get("status") != "scanned"]
    total_findings = sum(r.get("finding_count", 0) for r in scanned)

    by_detector = defaultdict(int)
    high_priority_count = 0
    low_priority_count = 0
    for r in scanned:
        for f_ in r.get("findings", []):
            by_detector[f_.get("detector", "unknown")] += 1
            if priority_for(f_) == "high":
                high_priority_count += 1
            else:
                low_priority_count += 1

    flagged_repos = [r for r in scanned if r.get("finding_count", 0) > 0]
    flagged_repos.sort(key=lambda r: r["finding_count"], reverse=True)

    merged = {
        "company": company,
        "total_repos_scanned": total_repos,
        "total_verified_findings": total_findings,
        "high_priority_findings": high_priority_count,
        "low_priority_findings": low_priority_count,
        "repos_with_findings": len(flagged_repos),
        "repos_failed": len(failed),
        "findings_by_detector": dict(by_detector),
        "repos": all_repos,
    }
    (results_dir / "summary.json").write_text(json.dumps(merged, indent=2))

    # ---- Build the Markdown summary -----------------------------------
    lines = []
    lines.append(f"# 🔐 Secret Scan Report — {company}")
    lines.append("")
    status_emoji = "🟢" if total_findings == 0 else "🔴"
    lines.append(f"{status_emoji} **{total_findings}** verified secret(s) found across "
                 f"**{len(flagged_repos)}** of **{total_repos}** scanned repositories.")
    if total_findings:
        lines.append(
            f"&nbsp;&nbsp;↳ **{high_priority_count} high-priority** (only recoverable "
            f"from deleted/dangling git history — someone tried to remove them) · "
            f"**{low_priority_count} low-priority** (still sitting in a current, "
            f"tracked file — more likely a known/intentional fixture, review before reporting)."
        )
    lines.append("")

    lines.append("| Metric | Value |")
    lines.append("|---|---|")
    lines.append(f"| Repos scanned | {total_repos} |")
    lines.append(f"| Repos with verified secrets | {len(flagged_repos)} |")
    lines.append(f"| Repos that failed to clone/scan | {len(failed)} |")
    lines.append(f"| Total verified findings | {total_findings} |")
    lines.append(f"| ‣ High priority (history-only) | {high_priority_count} |")
    lines.append(f"| ‣ Low priority (already in current HEAD) | {low_priority_count} |")
    lines.append("")

    if by_detector:
        lines.append("## Findings by secret type")
        lines.append("")
        lines.append("| Detector | Count |")
        lines.append("|---|---|")
        for det, count in sorted(by_detector.items(), key=lambda kv: kv[1], reverse=True):
            lines.append(f"| {det} | {count} |")
        lines.append("")

    if flagged_repos:
        lines.append("## Repositories with verified secrets")
        lines.append("")
        lines.append("| Repo | Findings | High priority | Low priority |")
        lines.append("|---|---|---|---|")
        for r in flagged_repos:
            hp = sum(1 for f_ in r["findings"] if priority_for(f_) == "high")
            lp = r["finding_count"] - hp
            lines.append(f"| `{r['repo']}` | {r['finding_count']} | {hp} | {lp} |")
        lines.append("")

        lines.append("### Per-finding detail")
        lines.append("")
        lines.append("Secret *values* are never shown — only enough to triage where to look.")
        lines.append("")
        lines.append("| Repo | Detector | Priority | Source | File |")
        lines.append("|---|---|---|---|---|")
        for r in flagged_repos:
            for f_ in r["findings"]:
                pr = priority_for(f_)
                pr_label = "🔴 high" if pr == "high" else "🟡 low"
                src_label = SOURCE_LABEL.get(f_.get("source", "unknown"), "❓ unknown")
                lines.append(
                    f"| `{r['repo']}` | {f_.get('detector','unknown')} | {pr_label} | "
                    f"{src_label} | `{f_.get('file','unknown')}` |"
                )
        lines.append("")
        lines.append("> Full JSON detail is in the `summary.json` artifact.")
        lines.append("")
    else:
        lines.append("## ✅ No verified secrets found")
        lines.append("")
        lines.append("Nothing TruffleHog could confirm as a *live* credential turned up "
                     "in current files, restored deleted files, or dangling git objects.")
        lines.append("")

    if failed:
        lines.append("## ⚠️ Repos that could not be scanned")
        lines.append("")
        for r in failed:
            lines.append(f"- `{r['repo']}` — {r.get('status')}")
        lines.append("")

    lines.append("---")
    lines.append("*Secret values are never printed in this report — only the detector "
                 "name, file path, source (deleted history vs. current file) and a "
                 "verified/unverified flag. \"Low priority\" does not mean safe to ignore — "
                 "it means the secret is already sitting in the current tracked code, which "
                 "is just as consistent with a known test fixture as with an unnoticed leak; "
                 "review the file before deciding whether to report it. Only scan "
                 "organizations you are authorized to test (your own org, or one with "
                 "an explicit bug-bounty/pentest scope that covers it).*")

    (results_dir / "summary.md").write_text("\n".join(lines))
    print("\n".join(lines))

if __name__ == "__main__":
    main()
