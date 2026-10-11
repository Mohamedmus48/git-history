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
    for r in scanned:
        for f_ in r.get("findings", []):
            by_detector[f_.get("detector", "unknown")] += 1

    flagged_repos = [r for r in scanned if r.get("finding_count", 0) > 0]
    flagged_repos.sort(key=lambda r: r["finding_count"], reverse=True)

    merged = {
        "company": company,
        "total_repos_scanned": total_repos,
        "total_verified_findings": total_findings,
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
    lines.append("")

    lines.append("| Metric | Value |")
    lines.append("|---|---|")
    lines.append(f"| Repos scanned | {total_repos} |")
    lines.append(f"| Repos with verified secrets | {len(flagged_repos)} |")
    lines.append(f"| Repos that failed to clone/scan | {len(failed)} |")
    lines.append(f"| Total verified findings | {total_findings} |")
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
        lines.append("| Repo | Findings |")
        lines.append("|---|---|")
        for r in flagged_repos:
            lines.append(f"| `{r['repo']}` | {r['finding_count']} |")
        lines.append("")
        lines.append("> Full per-finding detail (detector + file path, secret values "
                     "are redacted) is in the `summary.json` artifact, not printed here.")
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
                 "name, file path and a verified/unverified flag. Only scan "
                 "organizations you are authorized to test (your own org, or one with "
                 "an explicit bug-bounty/pentest scope that covers it).*")

    (results_dir / "summary.md").write_text("\n".join(lines))
    print("\n".join(lines))

if __name__ == "__main__":
    main()
