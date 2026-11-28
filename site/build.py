#!/usr/bin/env python3
"""Builds the Eider site into site/dist.

Plain files in, plain files out: site/src/template.html wraps each fragment in
site/src/pages/*.html, the stylesheet and icons are copied, and the screenshots
come straight from docs/images so the site never holds a second copy. The
release version is read from Casks/eider.rb so a release bump needs no edit
here. Standard library only; run it from anywhere:

    python3 site/build.py
"""

import html
import re
import shutil
import sys
from pathlib import Path

SITE = Path(__file__).resolve().parent
ROOT = SITE.parent
SRC = SITE / "src"
DIST = SITE / "dist"

BASE_URL = "https://ayush5harma.github.io/eider/"
REPO_URL = "https://github.com/ayush5harma/eider"

# (file stem, nav label). The first is the home page, written as index.html.
PAGES = [
    ("index", "Home"),
    ("sources", "Sources"),
    ("mac", "Mac app"),
    ("cli", "Command line"),
    ("ios", "Eider for iOS"),
    ("security", "Security and privacy"),
    ("faq", "FAQ"),
    ("build", "Build and licences"),
]

SCREENSHOTS = ["browse.png", "library.png", "updates.png"]
H2 = re.compile(r'<h2 id="([^"]+)">(.*?)</h2>', re.S)


def read_version() -> str:
    cask = (ROOT / "Casks" / "eider.rb").read_text()
    match = re.search(r'^\s*version\s+"([^"]+)"', cask, re.M)
    if not match:
        sys.exit("build.py: no version in Casks/eider.rb")
    return match.group(1)


def parse_fragment(path: Path) -> tuple[dict, str]:
    head, sep, body = path.read_text().partition("\n---\n")
    if not sep:
        sys.exit(f"build.py: {path.name} has no front matter ('---' line)")
    meta = {}
    for line in head.splitlines():
        key, _, value = line.partition(":")
        meta[key.strip()] = value.strip()
    for key in ("title", "description"):
        if not meta.get(key):
            sys.exit(f"build.py: {path.name} front matter lacks {key}")
    return meta, body


def nav_html(current: str) -> str:
    links = []
    for stem, label in PAGES:
        href = "./" if stem == "index" else f"{stem}.html"
        mark = ' aria-current="page"' if stem == current else ""
        links.append(f'<a href="{href}"{mark}>{html.escape(label)}</a>')
    return "\n".join(links)


def toc_html(body: str) -> str:
    items = [
        f'<li><a href="#{anchor}">{re.sub("<[^>]+>", "", text)}</a></li>'
        for anchor, text in H2.findall(body)
    ]
    if len(items) < 3:
        return ""
    return (
        '<nav class="toc" aria-label="On this page"><div class="toc-inner">'
        "<h2>On this page</h2><ol>" + "".join(items) + "</ol></div></nav>"
    )


def footer_links() -> str:
    out = []
    for stem, label in PAGES:
        href = "./" if stem == "index" else f"{stem}.html"
        out.append(f'<li><a href="{href}">{html.escape(label)}</a></li>')
    return "\n".join(out)


def render(template: str, stem: str, meta: dict, body: str, values: dict) -> str:
    toc = toc_html(body) if stem != "index" else ""
    layout = (
        f'<div class="wrap"><div class="page{" has-toc" if toc else ""}">{toc}'
        f'<article class="prose">{body}</article></div></div>'
        if stem != "index"
        else body
    )
    canonical = BASE_URL if stem == "index" else f"{BASE_URL}{stem}.html"
    title = meta["title"] if stem == "index" else f'{meta["title"]} - Eider'
    page = (
        template.replace("{{layout}}", layout)
        .replace("{{title}}", html.escape(title))
        .replace("{{description}}", html.escape(meta["description"], quote=True))
        .replace("{{canonical}}", canonical)
        .replace("{{nav}}", nav_html(stem))
        .replace("{{footer_links}}", footer_links())
    )
    for key, value in values.items():
        page = page.replace("{{" + key + "}}", value)
    leftover = re.findall(r"\{\{[a-z_]+\}\}", page)
    if leftover:
        sys.exit(f"build.py: unresolved placeholders in {stem}: {sorted(set(leftover))}")
    return page


def main() -> None:
    version = read_version()
    values = {
        "version": version,
        "repo": REPO_URL,
        "zip_url": f"{REPO_URL}/releases/download/v{version}/Eider-{version}.zip",
        "tar_url": f"{REPO_URL}/releases/download/v{version}/eider-{version}-macos-arm64.tar.gz",
        "release_url": f"{REPO_URL}/releases/tag/v{version}",
        "releases_url": f"{REPO_URL}/releases",
        "site_url": BASE_URL,
    }

    if DIST.exists():
        shutil.rmtree(DIST)
    (DIST / "assets").mkdir(parents=True)
    (DIST / "images").mkdir()

    for asset in (SRC / "assets").iterdir():
        shutil.copy2(asset, DIST / "assets" / asset.name)
    for name in SCREENSHOTS:
        shutil.copy2(ROOT / "docs" / "images" / name, DIST / "images" / name)

    template = (SRC / "template.html").read_text()
    for stem, _ in PAGES:
        meta, body = parse_fragment(SRC / "pages" / f"{stem}.html")
        out = render(template, stem, meta, body, values)
        (DIST / f"{stem}.html").write_text(out)

    meta, body = parse_fragment(SRC / "pages" / "404.html")
    # A 404 is served at any depth, so its links and assets must be absolute.
    page = render(template, "404", meta, body, values)
    page = re.sub(
        r'(href|src)="(?!https?:|#|mailto:)([^"]*)"',
        lambda m: f'{m.group(1)}="{BASE_URL}{m.group(2).removeprefix("./")}"',
        page,
    )
    (DIST / "404.html").write_text(page)

    urls = [BASE_URL] + [f"{BASE_URL}{stem}.html" for stem, _ in PAGES if stem != "index"]
    sitemap = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        + "".join(f"  <url><loc>{u}</loc></url>\n" for u in urls)
        + "</urlset>\n"
    )
    (DIST / "sitemap.xml").write_text(sitemap)
    (DIST / "robots.txt").write_text(f"User-agent: *\nAllow: /\nSitemap: {BASE_URL}sitemap.xml\n")
    (DIST / ".nojekyll").write_text("")

    print(f"built {len(PAGES) + 1} pages for Eider {version} into {DIST}")


if __name__ == "__main__":
    main()
