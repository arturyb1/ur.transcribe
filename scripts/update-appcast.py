#!/usr/bin/env python3
"""Adds (or replaces) one release in appcast.xml, newest first.

    scripts/update-appcast.py --version 0.1.2 --build 3 \
        --url https://github.com/.../ur.transcribe-0.1.2-macos-arm64.zip \
        --signature 'sparkle:edSignature="..." length="..."' \
        --notes-html notes.html --link https://github.com/.../releases/tag/v0.1.2
"""

import argparse
import re
from email.utils import formatdate
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--appcast", default="appcast.xml")
parser.add_argument("--version", required=True, help="CFBundleShortVersionString")
parser.add_argument("--build", required=True, help="CFBundleVersion; Sparkle compares this")
parser.add_argument("--url", required=True, help="download URL of the signed zip")
parser.add_argument("--signature", required=True, help="the attributes sign_update prints")
parser.add_argument("--notes-html", required=True, help="file with the release notes as HTML")
parser.add_argument("--link", required=True, help="release page")
parser.add_argument("--min-system", default="26.0")
args = parser.parse_args()

signature = args.signature.strip()
if not re.fullmatch(r'sparkle:edSignature="[^"]+" length="\d+"', signature):
    raise SystemExit(f"unexpected sign_update output: {signature!r}")

notes = Path(args.notes_html).read_text().replace("]]>", "]]&gt;")
item = f"""    <item>
      <title>Version {args.version}</title>
      <link>{args.link}</link>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{args.build}</sparkle:version>
      <sparkle:shortVersionString>{args.version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{args.min_system}</sparkle:minimumSystemVersion>
      <description><![CDATA[{notes}]]></description>
      <enclosure url="{args.url}" type="application/octet-stream" {signature}/>
    </item>
"""

path = Path(args.appcast)
feed = path.read_text()
# Re-running a release replaces its entry instead of duplicating it.
feed = re.sub(
    rf"    <item>(?:(?!</item>).)*<sparkle:version>{re.escape(args.build)}</sparkle:version>.*?</item>\n",
    "", feed, flags=re.S)
anchor = "    <language>en</language>\n"
if anchor not in feed:
    raise SystemExit("appcast.xml has no <language> line to insert after")
path.write_text(feed.replace(anchor, anchor + item, 1))
print(f"appcast: added {args.version} (build {args.build})")
