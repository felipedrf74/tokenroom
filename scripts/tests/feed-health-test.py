#!/usr/bin/env python3
"""feed-health.py without the network: the catalog it reads, and how it judges an answer."""
import importlib.util
from datetime import datetime, timezone
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("feed_health", Path(__file__).resolve().parents[1] / "feed-health.py")
health = importlib.util.module_from_spec(spec)
spec.loader.exec_module(health)

NOW = datetime(2026, 11, 7, 12, tzinfo=timezone.utc)


def rss(date="Thu, 05 Nov 2026 12:00:00 GMT", items=2):
    entries = "".join(f"<item><title>Post {n}</title><pubDate>{date}</pubDate></item>" for n in range(items))
    return f"<rss version=\"2.0\"><channel><title>Feed</title>{entries}</channel></rss>".encode()


class CatalogTests(unittest.TestCase):
    def test_reads_every_kind_from_the_swift_catalog(self):
        sources = {source.id: source for source in health.catalog()}
        for identifier, kind in [("claude-code", "official"), ("mistral-news", "official"), ("status-github", "status"),
                                 ("status-spacexai", "status"), ("voice-importai", "voice"), ("discussion-techmeme", "voice"),
                                 ("openrouter-models", "models"), ("clawhub-trending", "skills")]:
            with self.subTest(identifier=identifier):
                self.assertEqual(sources[identifier].kind, kind)
        self.assertEqual(sources["codex-changelog"].limit, 8 * 1024 * 1024)
        self.assertEqual(sources["claude-code"].limit, health.DEFAULT_LIMIT)
        self.assertNotIn("voice-embirico", sources, "A voice without a feed has nothing to check")
        self.assertTrue(all(source.url.startswith("https://") for source in sources.values()))
        self.assertEqual(len(sources), len(health.catalog()), "IDs are unique")


class AssessTests(unittest.TestCase):
    official = health.Source("o", "Official", "https://example.com/o", "official")
    voice = health.Source("v", "Voice", "https://example.com/v", "voice")
    status = health.Source("s", "Status", "https://example.com/s", "status")

    def test_a_current_feed_is_healthy(self):
        result = health.assess(self.official, 200, rss(), now=NOW)
        self.assertEqual(result.problems, [])
        self.assertEqual(result.entries, 2)

    def test_gone_broken_and_oversized_feeds_need_attention(self):
        self.assertIn("gone", health.assess(self.official, 404, b"", now=NOW).problems[0])
        self.assertEqual(health.assess(self.official, 200, b"<html><body>Moved</body></html>", now=NOW).problems, ["not an RSS or Atom feed"])
        small = health.Source("o", "Official", "https://example.com/o", "official", limit=100)
        self.assertIn("past its", health.assess(small, 200, rss(), now=NOW).problems[0])
        near = health.Source("o", "Official", "https://example.com/o", "official", limit=int(len(rss()) / 0.9))
        self.assertIn("over 80%", health.assess(near, 200, rss(), now=NOW).problems[0])

    def test_staleness_follows_each_kind(self):
        old = rss("Mon, 14 Sep 2026 12:00:00 GMT")  # 54 days before NOW
        self.assertIn("nothing new since 2026-09-14", health.assess(self.official, 200, old, now=NOW).problems[0])
        self.assertEqual(health.assess(self.voice, 200, old, now=NOW).problems, [], "Voices have 60 days")
        self.assertEqual(health.assess(self.status, 200, rss("Mon, 01 Jun 2026 12:00:00 GMT"), now=NOW).problems, [], "A quiet status page is good news")

    def test_atom_dates_are_read(self):
        atom = b"<feed xmlns='http://www.w3.org/2005/Atom'><entry><title>A</title><updated>2026-11-06T10:00:00Z</updated></entry></feed>"
        result = health.assess(self.official, 200, atom, now=NOW)
        self.assertEqual(result.problems, [])
        self.assertEqual(result.newest, datetime(2026, 11, 6, 10, tzinfo=timezone.utc))

    def test_json_sources_keep_the_shape_tokenroom_reads(self):
        models = health.Source("openrouter-models", "Models", "https://openrouter.ai/api/v1/models", "models")
        self.assertEqual(health.assess(models, 200, b'{"data":[{"id":"a/b"}]}', now=NOW).problems, [])
        self.assertEqual(health.assess(models, 200, b'{"models":[]}', now=NOW).problems, ["no `data` list of models"])
        trending = health.Source("clawhub-trending", "Trending", "https://clawhub.ai/api/v1/trending", "skills")
        good = b'{"items":[{"source":"clawhub","slug":"x","displayName":"X","publisher":{"handle":"me"}},{"source":"skills-sh","slug":"y"}]}'
        self.assertEqual(health.assess(trending, 200, good, now=NOW).problems, [])
        self.assertTrue(health.assess(trending, 200, b'{"items":[{"source":"clawhub","slug":"x"}]}', now=NOW).problems)
        ranked = health.Source("clawhub-downloads", "Downloads", "https://clawhub.ai/api/v1/skills", "skills")
        deprecated = health.assess(ranked, 200, b'{"items":[{"ownerHandle":"me","slug":"x"}]}', {"deprecation": "true", "link": "</next>"}, now=NOW)
        self.assertEqual(deprecated.problems, ["deprecated; successor: `</next>`"])

    def test_server_text_reaches_the_issue_only_as_inline_code(self):
        ranked = health.Source("clawhub-downloads", "Downloads", "https://clawhub.ai/api/v1/skills", "skills")
        hostile = "</x>; rel=a | @someone `ping` [link](https://evil.example)\n| injected | row |"
        result = health.assess(ranked, 200, b'{"items":[{"ownerHandle":"me","slug":"x"}]}', {"deprecation": "true", "link": hostile}, now=NOW)
        problem = result.problems[0]
        self.assertTrue(problem.startswith("deprecated; successor: `") and problem.endswith("`"))
        inner = problem[len("deprecated; successor: `"):-1]
        self.assertNotIn("`", inner)
        self.assertNotIn("\n", inner)
        self.assertNotIn(" | ", inner.replace("\\|", ""), "Pipes are escaped so the table holds")
        row = [line for line in health.report([result], now=NOW).splitlines() if line.startswith("| Downloads | `clawhub-downloads`")][0]
        self.assertEqual(row.replace("\\|", "").count("|"), 4, "One row, three cells")

    def test_report_lists_what_needs_attention_first(self):
        results = [health.assess(self.official, 200, rss(), now=NOW), health.assess(self.voice, 410, b"", now=NOW)]
        text = health.report(results, now=NOW)
        self.assertIn("2 sources checked; 1 need attention.", text)
        self.assertLess(text.index("## Needs attention"), text.index("## All sources"))
        self.assertIn("| Voice | `v` | HTTP 410 (gone) |", text)


if __name__ == "__main__":
    unittest.main()
