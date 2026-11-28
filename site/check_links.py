#!/usr/bin/env python3
"""Checks the built site: every internal link, asset and #anchor resolves.

    python3 site/check_links.py [dist-dir] [--external]

Also fails on duplicate ids, images without alt text, a page without exactly one
<h1>, and any unresolved {{placeholder}}. With --external it sends a HEAD (then
GET) request to every distinct https link outside the site, four at a time, and
reports the ones that do not answer with a 2xx or 3xx. Standard library only.
"""

import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urldefrag, urljoin, urlsplit

BASE_URL = "https://ayush5harma.github.io/eider/"


class PageScan(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.ids: list[str] = []
        self.links: list[str] = []
        self.h1 = 0
        self.bad_images: list[str] = []

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if "id" in attributes:
            self.ids.append(attributes["id"])
        if tag == "h1":
            self.h1 += 1
        if tag == "img" and attributes.get("alt") is None:
            self.bad_images.append(attributes.get("src", "?"))
        if tag == "a" and attributes.get("href"):
            self.links.append(attributes["href"])
        if tag == "link" and attributes.get("href") and attributes.get("rel") != "canonical":
            self.links.append(attributes["href"])
        if tag in ("img", "script", "source") and attributes.get("src"):
            self.links.append(attributes["src"])


def check_external(url: str) -> str | None:
    for method in ("HEAD", "GET"):
        request = urllib.request.Request(url, method=method, headers={"User-Agent": "eider-site-link-check"})
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                if response.status < 400:
                    return None
        except urllib.error.HTTPError as error:
            if method == "GET":
                return f"HTTP {error.code}"
        except Exception as error:  # network failures are reported, not raised
            if method == "GET":
                return str(error)
    return "no answer"


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dist = Path(args[0] if args else Path(__file__).resolve().parent / "dist").resolve()
    external = "--external" in sys.argv
    if not dist.is_dir():
        print(f"no such folder: {dist} (run site/build.py first)")
        return 2

    pages = sorted(dist.glob("*.html"))
    scans: dict[Path, PageScan] = {}
    problems: list[str] = []
    for page in pages:
        text = page.read_text()
        scan = PageScan()
        scan.feed(text)
        scans[page] = scan
        if "{{" in text:
            problems.append(f"{page.name}: unresolved placeholder")
        if scan.h1 != 1:
            problems.append(f"{page.name}: {scan.h1} h1 elements, want 1")
        seen = set()
        for ident in scan.ids:
            if ident in seen:
                problems.append(f"{page.name}: duplicate id {ident!r}")
            seen.add(ident)
        for src in scan.bad_images:
            problems.append(f"{page.name}: image without alt: {src}")

    external_links: dict[str, list[str]] = {}
    checked = 0
    for page, scan in scans.items():
        for link in scan.links:
            checked += 1
            if link.startswith("mailto:"):
                continue
            if link.startswith(BASE_URL):
                link = link[len(BASE_URL):] or "./"
            elif link.startswith(("http://", "https://")):
                external_links.setdefault(urldefrag(link)[0], []).append(page.name)
                continue
            url, fragment = urldefrag(link)
            target_path = unquote(urlsplit(urljoin(f"file:///{page.name}", url)).path).lstrip("/")
            target = (dist / target_path) if target_path else page
            if target.is_dir():
                target = target / "index.html"
            if not target.exists():
                problems.append(f"{page.name}: broken link {link!r} (no {target.relative_to(dist)})")
                continue
            if fragment:
                target_scan = scans.get(target)
                if target_scan is None:
                    problems.append(f"{page.name}: anchor on a non-page {link!r}")
                elif fragment not in target_scan.ids:
                    problems.append(f"{page.name}: missing anchor {link!r}")

    if external and external_links:
        urls = sorted(external_links)
        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(check_external, urls))
        for url, result in zip(urls, results):
            if result:
                problems.append(f"external {url}: {result} (on {', '.join(sorted(set(external_links[url])))})")

    print(
        f"{len(pages)} pages, {checked} links checked, "
        f"{len(external_links)} distinct external links{' (checked)' if external else ' (not checked; use --external)'}"
    )
    for problem in problems:
        print("FAIL", problem)
    if not problems:
        print("ok")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
