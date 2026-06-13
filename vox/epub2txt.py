#!/usr/bin/env python3
"""
epub2txt.py — Extract reading-order plain text from an EPUB, no external deps.

Reads the spine order from the OPF so chapters come out in the right sequence,
strips HTML, and writes UTF-8 text. Useful for feeding audiobook.py.

Usage:
    python epub2txt.py book.epub -o book.txt
    python epub2txt.py book.epub -o sample.txt --max-chars 1500   # short sample
"""
import argparse
import html
import re
import sys
import zipfile
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote
from xml.etree import ElementTree as ET

SKIP_TAGS = {"script", "style", "head", "title"}
BLOCK_TAGS = {"p", "div", "br", "li", "h1", "h2", "h3", "h4", "h5", "h6",
              "tr", "blockquote", "section", "article"}


class TextExtractor(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts = []
        self._skip = 0

    def handle_starttag(self, tag, attrs):
        if tag in SKIP_TAGS:
            self._skip += 1
        elif tag in BLOCK_TAGS:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in SKIP_TAGS and self._skip:
            self._skip -= 1
        elif tag in BLOCK_TAGS:
            self.parts.append("\n")

    def handle_data(self, data):
        if not self._skip:
            self.parts.append(data)

    def text(self):
        raw = "".join(self.parts)
        raw = html.unescape(raw)
        # collapse spaces, keep paragraph breaks
        raw = re.sub(r"[ \t ]+", " ", raw)
        raw = re.sub(r"\n[ \t]+", "\n", raw)
        raw = re.sub(r"\n{2,}", "\n\n", raw)
        return raw.strip()


def spine_documents(zf: zipfile.ZipFile):
    """Return content document paths in spine (reading) order."""
    # locate the OPF via META-INF/container.xml
    container = zf.read("META-INF/container.xml")
    ns = {"c": "urn:oasis:names:tc:opendocument:xmlns:container"}
    root = ET.fromstring(container)
    opf_path = root.find(".//c:rootfile", ns).get("full-path")
    opf_dir = "/".join(opf_path.split("/")[:-1])

    opf = ET.fromstring(zf.read(opf_path))
    # strip default namespace for easy tag matching
    def lt(e):  # local tag
        return e.tag.split("}")[-1]

    manifest = {}
    spine = []
    for el in opf.iter():
        t = lt(el)
        if t == "item":
            manifest[el.get("id")] = el.get("href")
        elif t == "itemref":
            spine.append(el.get("idref"))

    docs = []
    for idref in spine:
        href = manifest.get(idref)
        if not href:
            continue
        path = unquote(f"{opf_dir}/{href}" if opf_dir else href)
        docs.append(path)
    return docs


def extract_epub(epub_path, max_chars: int = 0) -> str:
    """Extract reading-order plain text from an EPUB file path. Returns a string."""
    with zipfile.ZipFile(epub_path) as zf:
        names = set(zf.namelist())
        try:
            docs = spine_documents(zf)
        except Exception as e:
            print(f"(spine read failed: {e}; falling back to file order)", file=sys.stderr)
            docs = sorted(n for n in names if n.lower().endswith((".xhtml", ".html", ".htm")))

        chunks = []
        total = 0
        for path in docs:
            if path not in names:
                continue
            try:
                raw = zf.read(path).decode("utf-8", errors="replace")
            except KeyError:
                continue
            ex = TextExtractor()
            ex.feed(raw)
            txt = ex.text()
            if txt:
                chunks.append(txt)
                total += len(txt)
            if max_chars and total >= max_chars:
                break

    full = "\n\n".join(chunks)
    if max_chars:
        full = full[:max_chars]
    return full


def main():
    ap = argparse.ArgumentParser(description="Extract plain text from an EPUB.")
    ap.add_argument("epub")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--max-chars", type=int, default=0,
                    help="If >0, stop after this many characters (for a sample).")
    args = ap.parse_args()

    full = extract_epub(args.epub, max_chars=args.max_chars)
    Path(args.output).write_text(full, encoding="utf-8")
    print(f"Wrote {args.output}: {len(full)} chars.")


if __name__ == "__main__":
    main()
