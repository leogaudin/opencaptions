#!/usr/bin/env python3
"""The week on one page: the store, crashes, the repository and the speech models.

    ASC_KEY_ID=... ASC_ISSUER=... python3 scripts/weekly.py <folder>

Writes <folder>/<date>.md and keeps what it saw in <folder>/state.json, so that a new review or a model
that moved stands out from the week before. It only reads: answering a review, or testing a model that
moved, is for a person to decide. Sales and analytics need a key with more access than App Manager.
"""

from __future__ import annotations

import datetime
import json
import subprocess
import sys
import urllib.request
from pathlib import Path
from typing import Any

import asc

# What the app downloads from Hugging Face. FluidAudio and WhisperKit both take `main`, so a change upstream
# reaches users with no release of ours: a fresh download is what proves it still works.
MODELS = [
    "FluidInference/parakeet-ultra-coreml",
    "FluidInference/parakeet-redux-coreml",
    "argmaxinc/whisperkit-coreml",
]


def store() -> list[str]:
    app = asc.get(f"/v1/apps?filter[bundleId]={asc.BUNDLE_ID}")["data"][0]["id"]
    lines = ["## Store", ""]
    for version in asc.get(f"/v1/apps/{app}/appStoreVersions?limit=5")["data"]:
        a = version["attributes"]
        lines.append(f"- {a['platform']} {a['versionString']}: {a['appVersionState']}")
    return lines


def reviews(state: dict[str, Any]) -> list[str]:
    app = asc.get(f"/v1/apps?filter[bundleId]={asc.BUNDLE_ID}")["data"][0]["id"]
    found = asc.get(f"/v1/apps/{app}/customerReviews?limit=50&sort=-createdDate")["data"]
    seen = set(state.get("reviews", []))
    fresh = [r for r in found if r["id"] not in seen]
    state["reviews"] = sorted(seen | {r["id"] for r in found})
    lines = ["", f"## Reviews ({len(fresh)} new, {len(state['reviews'])} in all)", ""]
    for review in fresh:
        a = review["attributes"]
        lines += [f"- {a['rating']}/5, {a['territory']}, {a['createdDate'][:10]}: **{a['title']}**", f"  {a['body']}"]
    return lines


def crashes() -> list[str]:
    app = asc.get(f"/v1/apps?filter[bundleId]={asc.BUNDLE_ID}")["data"][0]["id"]
    lines = ["", "## Crashes and hangs", ""]
    for build in asc.get(f"/v1/builds?filter[app]={app}&limit=4&sort=-uploadedDate")["data"]:
        signatures = asc.get(f"/v1/builds/{build['id']}/diagnosticSignatures?limit=10").get("data", [])
        for signature in signatures:
            a = signature["attributes"]
            lines.append(f"- {build['attributes']['version']}, {a['diagnosticType']}, weight {a['weight']}: {a['signature']}")
    return lines if len(lines) > 3 else [*lines, "None reported by Apple on the last four builds."]


def repository() -> list[str]:
    def gh(path: str, query: str) -> str:
        return subprocess.run(["gh", "api", path, "--jq", query], capture_output=True, text=True).stdout.strip()

    base = "repos/leogaudin/opencaptions"
    counts = gh(base, '"\\(.stargazers_count) stars, \\(.forks_count) forks, \\(.open_issues_count) open issues"')
    views = gh(f"{base}/traffic/views", '"\\(.count) views by \\(.uniques) people in 14 days"')
    return ["", "## Repository", "", f"- {counts}", f"- {views}"]


def models(state: dict[str, Any]) -> list[str]:
    known = state.setdefault("models", {})
    lines = ["", "## Speech models", ""]
    for repository_id in MODELS:
        with urllib.request.urlopen(f"https://huggingface.co/api/models/{repository_id}", timeout=30) as response:
            sha = json.load(response)["sha"]
        moved = repository_id in known and known[repository_id] != sha
        note = "**moved: test a fresh download**" if moved else "unchanged" if repository_id in known else "first seen"
        lines.append(f"- {repository_id}: `{sha[:12]}`, {note}")
        known[repository_id] = sha
    return lines


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    folder = Path(sys.argv[1])
    folder.mkdir(parents=True, exist_ok=True)
    saved = folder / "state.json"
    state = json.loads(saved.read_text()) if saved.exists() else {}
    today = datetime.date.today().isoformat()
    page = [f"# Week of {today}", "", *store(), *reviews(state), *crashes(), *repository(), *models(state)]
    (folder / f"{today}.md").write_text("\n".join(page) + "\n", encoding="utf-8")
    saved.write_text(json.dumps(state, indent=2) + "\n")
    print("\n".join(page))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
