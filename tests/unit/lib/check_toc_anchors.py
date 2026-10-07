#!/usr/bin/env python3
"""Every in-page link in a Markdown file resolves to a heading.

Used by tests/unit/test_operator_surfaces.sh (DEC-PHASE12-131). Slugs are
computed both the way GitHub does (readers of the repo) and the way
python-markdown's toc extension does (the HTML 0810 renders onto the deck);
a link must resolve under both. Prints "OK <n> links" or "FAIL ..." lines.

argv: MARKDOWN_FILE
"""
import re
import sys
import unicodedata

text = open(sys.argv[1], encoding="utf-8").read()
# Headings outside fenced code blocks.
headings, fence = [], False
for line in text.split("\n"):
    if line.lstrip().startswith("```"):
        fence = not fence
        continue
    m = None if fence else re.match(r"^(#{1,6})\s+(.*?)\s*#*\s*$", line)
    if m:
        headings.append(m.group(2))


def strip_md(h):
    h = re.sub(r"`([^`]*)`", r"\1", h)
    h = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", h)
    return h.replace("*", "")


def github_slug(h):
    h = strip_md(h).strip().lower()
    h = re.sub(r"[^\w\- ]", "", h)
    return h.replace(" ", "-")


def pymd_slug(h):
    # markdown.extensions.toc.slugify (separator "-")
    h = unicodedata.normalize("NFKD", strip_md(h)).encode("ascii", "ignore").decode()
    h = re.sub(r"[^\w\s-]", "", h).strip().lower()
    return re.sub(r"[-\s]+", "-", h)


def dedupe(slugs):
    seen, out = {}, set()
    for s in slugs:
        if s in seen:
            seen[s] += 1
            out.add(f"{s}-{seen[s]}" if s else s)
        else:
            seen[s] = 0
            out.add(s)
    return out


gh = dedupe(github_slug(h) for h in headings)
pm = dedupe(pymd_slug(h) for h in headings)
links = re.findall(r"\]\(#([^)\s]+)\)", text)
bad = []
for a in links:
    where = [name for name, pool in (("GitHub", gh), ("rendered HTML", pm)) if a not in pool]
    if where:
        bad.append(f"FAIL #{a} does not resolve on {' and '.join(where)}")
print("\n".join(bad) if bad else f"OK {len(links)} links")
