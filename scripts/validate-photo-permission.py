#!/usr/bin/env python3
"""Check the signed bundle, not just the source entitlement file."""
import argparse
import plistlib
import subprocess
from pathlib import Path

PHOTO_ENTITLEMENT = "com.apple.security.personal-information.photos-library"


def validate(entitlements, info):
    if entitlements.get(PHOTO_ENTITLEMENT) is not True:
        raise ValueError("App signature is missing the Photos Library entitlement; macOS will not show the permission prompt.")
    for key in ("NSPhotoLibraryUsageDescription", "NSPhotoLibraryAddUsageDescription"):
        if not isinstance(info.get(key), str) or not info[key].strip():
            raise ValueError(f"App Info.plist is missing {key}.")


def verify(app):
    result = subprocess.run(["codesign", "--display", "--entitlements", "-", "--xml", str(app)],
                            check=True, capture_output=True)
    entitlements = plistlib.loads(result.stdout) if result.stdout.strip() else {}
    with (app / "Contents/Info.plist").open("rb") as source:
        validate(entitlements, plistlib.load(source))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    verify(args.app)
    print("Signed Photos Library permission configuration verified.")
