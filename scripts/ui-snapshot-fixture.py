#!/usr/bin/env python3
"""Write a synthetic News fixture (news.json, skills.json) for screenshots.

Everything here is made up for layout review: no live feed, account, or person's data. Usage:
    scripts/ui-snapshot-fixture.py <folder>
"""
import json
import sys
import time
from pathlib import Path

folder = Path(sys.argv[1])
folder.mkdir(parents=True, exist_ok=True)
now = time.time()
hour, day = 3600, 86_400


def item(feed, source, title, age, excerpt, kind="officialAnnouncement"):
    date = now - age
    return {
        "id": f"{feed}-{int(age)}", "title": title, "source": source, "sourceID": feed,
        "link": f"https://example.com/{feed}/{int(age)}", "published": date, "firstSeenAt": date,
        "publisherPublishedAt": date, "excerpt": excerpt, "excerptIsPlainText": True, "kind": kind,
    }


items = {
    "claude-code": [
        item("claude-code", "Claude Code", "Sample release: background agents and a calmer status line", 3 * hour,
             "Placeholder notes for layout review. Long-running agents keep working while you move on, and the status line now shows one thing at a time."),
        item("claude-code", "Claude Code", "Sample release: faster resume for large sessions", 2 * day,
             "Placeholder notes for layout review. Reopening a long session takes a fraction of the time it did."),
    ],
    "openai-news": [
        item("openai-news", "OpenAI", "Sample announcement: longer context for coding plans", 9 * hour,
             "Placeholder announcement for layout review. Plans read more of a repository before they answer."),
    ],
    "codex-releases": [
        item("codex-releases", "Codex", "Sample release 2.14: reviews run alongside your edits", 20 * hour,
             "Placeholder notes for layout review. A review now keeps pace with the change it is reading."),
    ],
    "gemini": [
        item("gemini", "Google Gemini", "Sample post: what changed in this month's Gemini update", 30 * hour,
             "Placeholder post for layout review, with enough words to wrap across two lines in a list."),
    ],
    "cursor": [
        item("cursor", "Cursor", "Sample changelog: tab completions learn your repository", 2 * day,
             "Placeholder changelog for layout review."),
    ],
    "copilot": [
        item("copilot", "GitHub Copilot", "Sample changelog: agent mode in more editors", 3 * day,
             "Placeholder changelog for layout review."),
    ],
    "deepmind": [
        item("deepmind", "Google DeepMind", "Sample research note: planning across long tasks", 4 * day,
             "Placeholder research summary for layout review."),
    ],
    "voice-simonw": [
        item("voice-simonw", "Simon Willison", "Sample commentary: notes on this week's models", 6 * hour,
             "Placeholder commentary for layout review.", "commentary"),
    ],
}

models = [
    {"id": "anthropic/sample-claude-model", "name": "Anthropic: Sample Claude Model", "vendor": "anthropic", "created": now - 2 * day,
     "contextLength": 1_000_000, "promptPrice": 5.0, "completionPrice": 25.0, "firstSeenAt": now - 2 * day},
    {"id": "openai/sample-gpt-model", "name": "OpenAI: Sample GPT Model", "vendor": "openai", "created": now - 5 * day,
     "contextLength": 400_000, "promptPrice": 2.5, "completionPrice": 10.0, "firstSeenAt": now - 5 * day},
    {"id": "x-ai/sample-grok-model", "name": "xAI: Sample Grok Model", "vendor": "x-ai", "created": now - 8 * day,
     "contextLength": 2_000_000, "promptPrice": 3.0, "completionPrice": 15.0, "firstSeenAt": now - 8 * day},
    {"id": "google/sample-gemini-model", "name": "Google: Sample Gemini Model", "vendor": "google", "created": now - 11 * day,
     "contextLength": 1_000_000, "promptPrice": 1.25, "completionPrice": 5.0, "firstSeenAt": now - 11 * day},
    {"id": "openai/sample-retiring-model", "name": "OpenAI: Sample Retiring Model", "vendor": "openai", "created": now - 400 * day,
     "contextLength": 128_000, "promptPrice": 1.0, "completionPrice": 2.0, "expires": now + 12 * day},
]

checks = {feed: {"succeededAt": now - 120} for feed in items}
cache = {
    "sourceChecks": checks, "models": models, "modelsFetchedAt": now - 120, "modelState": {"seenIDs": []},
    "items": items, "announcementsFetchedAt": now - 120, "validators": {},
}
(folder / "news.json").write_text(json.dumps(cache))

skills = [
    ("sample-labs", "repo-map", "Repo map", "Draws a map of an unfamiliar repository before you change it.", 1240),
    ("sample-labs", "release-notes", "Release notes", "Turns a branch's commits into notes people read.", 980),
    ("tinker", "pr-review", "PR review", "Reads a pull request the way a careful teammate would.", 870),
    ("tinker", "test-gaps", "Test gaps", "Finds the behaviour your tests never exercise.", 640),
    ("northwind", "changelog", "Changelog", "Keeps a changelog honest as a branch moves.", 510),
]
listing = [{"ownerHandle": o, "slug": s, "displayName": n, "summary": d,
            "stats": {"installsCurrent": c, "installsAllTime": c * 9, "downloads": c * 14, "stars": c // 7}}
           for o, s, n, d, c in skills]
(folder / "skills.json").write_text(json.dumps({"items": listing}))
print(folder / "news.json")
