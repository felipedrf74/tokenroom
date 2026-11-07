#!/usr/bin/env python3
"""Checks every public source News and Skills read, live, and reports what needs attention.

Advisory: it never fails a build. The weekly `Feed health` workflow runs it and opens or
updates one issue. The catalog is read from the Swift sources, so there is no second list:
`FeedSource.catalog` (Shared/Core/Feeds.swift), `NewsVoice.catalog` and `NewsStatusSource`
(Shared/Core/NewsSources.swift), OpenRouter's model list, and ClawHub's rankings.

A source needs attention when it doesn't answer 200, isn't a feed (or, for the JSON sources,
the shape Tokenroom reads), is past its size limit (or within 80% of it), or hasn't published in
30 days (official feeds) or 60 (voices and discussion). Status feeds may be quiet: a quiet one is
fine. Run it locally with `python3 scripts/feed-health.py`.
"""
import argparse
import concurrent.futures
import gzip
import json
import re
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
import zlib
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LIMIT = 2 * 1024 * 1024
USER_AGENT = "Tokenroom feed-health"
STALE_DAYS = {"official": 30, "voice": 60, "status": None, "models": None, "skills": None}
NEAR_LIMIT = 0.8


@dataclass
class Source:
    id: str
    name: str
    url: str
    kind: str  # official, status, voice, models, skills
    limit: int = DEFAULT_LIMIT


@dataclass
class Result:
    source: Source
    status: int | None = None
    size: int = 0
    entries: int = 0
    newest: datetime | None = None
    problems: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)


def code(text, limit=200):
    """Server-supplied text (a Link header, an error's reason) as inline code in the issue:
    no Markdown, mentions or links of its own, and no `|` to break the table."""
    text = " ".join(str(text).split())[:limit].replace("`", "'").replace("\\", "/").replace("|", "\\|")
    return f"`{text}`"


def _limit(text):
    match = re.search(r"sizeLimit:\s*(\d+)\s*\*\s*1024\s*\*\s*1024", text)
    return int(match.group(1)) * 1024 * 1024 if match else DEFAULT_LIMIT


def catalog(root=ROOT):
    """Every source, read from the Swift catalog."""
    sources = []
    feed = re.compile(r'FeedSource\(id: "([^"]+)", name: "([^"]+)", url: URL\(string: "([^"]+)"\)!([^\n]*)')
    for path in ["Shared/Core/Feeds.swift", "Shared/Core/NewsSources.swift"]:
        for match in feed.finditer((root / path).read_text()):
            identifier, name, url, rest = match.groups()
            if ".officialStatus" in rest:
                kind = "status"
            elif ".commentary" in rest:
                continue  # The voices' helper below makes these.
            else:
                kind = "official"
            sources.append(Source(identifier, name, url, kind, _limit(rest)))
    # The third argument is an X handle, or `site: "…"` for a publication without its own account.
    voice = re.compile(r'voice\("([^"]+)", "([^"]+)", (?:site: )?"[^"]+", "([^"]+)", "[^"]+"([^\n]*)\)')
    for match in voice.finditer((root / "Shared/Core/NewsSources.swift").read_text()):
        identifier, name, url, rest = match.groups()
        prefix = "discussion-" if ".discussion" in rest else "voice-"
        sources.append(Source(prefix + identifier, name, url, "voice"))
    models = re.search(r'static let url = URL\(string: "([^"]+)"\)!', (root / "Shared/Core/Feeds.swift").read_text())
    if models:
        sources.append(Source("openrouter-models", "OpenRouter model list", models.group(1), "models"))
    sources.append(Source("clawhub-trending", "ClawHub trending", "https://clawhub.ai/api/v1/trending?kind=skills&limit=30&nonSuspiciousOnly=true", "skills"))
    sources.append(Source("clawhub-downloads", "ClawHub most downloaded", "https://clawhub.ai/api/v1/skills?sort=downloads&limit=30&nonSuspiciousOnly=true", "skills"))
    return sources


def parse_date(text):
    text = (text or "").strip()
    if not text:
        return None
    try:
        date = parsedate_to_datetime(text)
    except (TypeError, ValueError, IndexError):
        try:
            date = datetime.fromisoformat(text.replace("Z", "+00:00"))
        except ValueError:
            return None
    return date if date.tzinfo else date.replace(tzinfo=timezone.utc)


def local(tag):
    return tag.rsplit("}", 1)[-1]


def read_feed(body):
    """(is a feed, entries, newest date) for an RSS or Atom document."""
    try:
        root = ET.fromstring(body)
    except ET.ParseError:
        return False, 0, None
    if local(root.tag) == "rss":
        channel = next((child for child in root if local(child.tag) == "channel"), None)
        if channel is None:
            return False, 0, None
        entries = [child for child in channel if local(child.tag) == "item"]
        fields = {"pubDate", "date", "updated", "published"}
    elif local(root.tag) == "feed":
        entries = [child for child in root if local(child.tag) == "entry"]
        fields = {"updated", "published"}
    else:
        return False, 0, None
    dates = [parse_date(node.text) for entry in entries for node in entry if local(node.tag) in fields]
    dates = [date for date in dates if date]
    return True, len(entries), max(dates) if dates else None


def read_json(source, body):
    """Problems with a JSON source's shape, as Tokenroom reads it."""
    try:
        root = json.loads(body)
    except ValueError:
        return 0, ["not JSON"]
    if source.kind == "models":
        items = root.get("data") if isinstance(root, dict) else None
        return (len(items), []) if isinstance(items, list) and items else (0, ["no `data` list of models"])
    items = root.get("items") if isinstance(root, dict) else None
    if not isinstance(items, list) or not items:
        return 0, ["no `items` list"]
    if source.id == "clawhub-trending":
        usable = [item for item in items if isinstance(item, dict) and item.get("source") == "clawhub"
                  and ((item.get("publisher") or {}).get("handle") or (item.get("sourceIdentity") or {}).get("owner"))]
        if not usable or not all("slug" in item and "displayName" in item for item in usable):
            return len(items), ["trending items lack `publisher.handle`/`sourceIdentity.owner`, `slug` or `displayName`"]
        return len(usable), []
    if not all(isinstance(item, dict) and "ownerHandle" in item and "slug" in item for item in items):
        return len(items), ["items lack `ownerHandle` or `slug`"]
    return len(items), []


def assess(source, status, body, headers=None, now=None):
    """The result for one answer: pure, so the tests can feed it."""
    now = now or datetime.now(timezone.utc)
    result = Result(source, status=status, size=len(body))
    if status != 200:
        result.problems.append(f"HTTP {status}" + (" (gone)" if status in (404, 410) else ""))
        return result
    if result.size > source.limit:
        result.problems.append(f"{result.size:,} bytes, past its {source.limit:,}-byte limit")
    elif result.size > source.limit * NEAR_LIMIT:
        result.problems.append(f"{result.size:,} bytes, over {int(NEAR_LIMIT * 100)}% of its {source.limit:,}-byte limit")
    if source.kind in ("models", "skills"):
        result.entries, problems = read_json(source, body)
        result.problems += problems
        deprecation = (headers or {}).get("deprecation")
        if deprecation and deprecation.lower() != "false":
            link = (headers or {}).get("link")
            result.problems.append(f"deprecated; successor: {code(link) if link else 'not named'}")
        return result
    is_feed, result.entries, result.newest = read_feed(body)
    if not is_feed:
        result.problems.append("not an RSS or Atom feed")
        return result
    if result.entries == 0:
        result.problems.append("no entries")
    stale = STALE_DAYS.get(source.kind)
    if stale and result.newest and now - result.newest > timedelta(days=stale):
        result.problems.append(f"nothing new since {result.newest:%Y-%m-%d} (over {stale} days)")
    elif stale and result.entries and not result.newest:
        result.notes.append("entries carry no dates")
    return result


def fetch(source, timeout=30):
    request = urllib.request.Request(source.url, headers={"User-Agent": USER_AGENT, "Accept-Encoding": "gzip, deflate",
                                                          "Accept": "application/rss+xml, application/atom+xml, application/json, */*;q=0.5"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read(source.limit * 4)
            encoding = (response.headers.get("Content-Encoding") or "").lower()
            body = gzip.decompress(raw) if encoding == "gzip" else zlib.decompress(raw) if encoding == "deflate" else raw
            headers = {key.lower(): value for key, value in response.headers.items()}
            return response.status, body, headers
    except urllib.error.HTTPError as error:
        return error.code, b"", {}
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        return None, str(getattr(error, "reason", error)).encode(), {}


def check(source):
    status, body, headers = fetch(source)
    if status is None:
        result = Result(source)
        result.problems.append(f"no answer: {code(body.decode(errors='replace'))}")
        return result
    return assess(source, status, body, headers)


def report(results, now=None):
    now = now or datetime.now(timezone.utc)
    failing = [result for result in results if result.problems]
    lines = [f"# Feed health, {now:%Y-%m-%d}", "",
             f"{len(results)} sources checked; {len(failing)} need attention." if failing else f"{len(results)} sources checked; all healthy.", ""]
    if failing:
        lines += ["## Needs attention", "", "| Source | ID | Problem |", "|---|---|---|"]
        lines += [f"| {r.source.name} | `{r.source.id}` | {'; '.join(r.problems)} |" for r in failing]
        lines.append("")
    lines += ["## All sources", "", "| Source | Kind | HTTP | Size | Limit | Entries | Newest |", "|---|---|---|---|---|---|---|"]
    for r in results:
        newest = f"{r.newest:%Y-%m-%d}" if r.newest else "-"
        lines.append(f"| {r.source.name} | {r.source.kind} | {r.status or '-'} | {r.size:,} | {r.source.limit:,} | {r.entries} | {newest} |")
    lines += ["", "Advisory, from `scripts/feed-health.py`. Fix a source in the Swift catalog; nothing here blocks a merge."]
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--output", type=Path, help="also write the Markdown report here")
    parser.add_argument("--status-file", type=Path, help="write `healthy` or `attention` here")
    args = parser.parse_args(argv)
    sources = catalog()
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        results = list(pool.map(check, sources))
    text = report(results)
    sys.stdout.write(text)
    if args.output:
        args.output.write_text(text)
    if args.status_file:
        args.status_file.write_text("attention" if any(r.problems for r in results) else "healthy")
    return 0  # Advisory: the report says what needs attention.


if __name__ == "__main__":
    sys.exit(main())
