#!/usr/bin/env python3
"""Fail before signing when a requested release tag is inconsistent or already used."""
import argparse
import json
import plistlib
import re
import subprocess
from pathlib import Path


def validate_tag(tag, version):
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag) or tag != "v" + version:
        raise ValueError("Release tag must exactly match the App version, for example v0.9.0.")


def validate_unused(tag, refs, releases):
    if any(ref.get("ref") == "refs/tags/" + tag for ref in refs):
        raise ValueError("Tag already exists; releases never retarget an existing tag.")
    if any(item.get("tag_name") == tag for item in releases):
        raise ValueError("Release already exists (including drafts); it will not be overwritten.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("tag")
    parser.add_argument("--repo", required=True)
    args = parser.parse_args()
    with (args.app / "Contents/Info.plist").open("rb") as source:
        version = plistlib.load(source)["CFBundleShortVersionString"]
    validate_tag(args.tag, version)
    def api(endpoint):
        return json.loads(subprocess.run(["gh", "api", "--paginate", "--slurp", endpoint],
                                         check=True, capture_output=True, text=True).stdout)
    refs = [item for page in api(f"repos/{args.repo}/git/matching-refs/tags/{args.tag}") for item in page]
    releases = [item for page in api(f"repos/{args.repo}/releases") for item in page]
    validate_unused(args.tag, refs, releases)
    print(f"Release preflight passed: {args.tag}")


if __name__ == "__main__": main()
