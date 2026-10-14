#!/usr/bin/env python3
"""Reject legacy-only icons, transparent source margins, and missing fallbacks."""
import json
import plistlib
import struct
import subprocess
import sys
import tempfile
from pathlib import Path


def verify(app):
    contents = Path(app) / "Contents"
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    name = info.get("CFBundleIconName")
    if name != "OCloudSync" or info.get("CFBundleIconFile") != "OCloudSync.icns":
        raise ValueError("App must reference the OCloudSync icon stack and ICNS fallback")
    resources = contents / "Resources"
    catalog = json.loads(subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "assetutil", "--info", str(resources / "Assets.car")]))
    stacks = [entry for entry in catalog
              if entry.get("AssetType") == "IconImageStack" and entry.get("Name") == name]
    if not stacks or any((s.get("CanvasWidth"), s.get("CanvasHeight")) != (1024, 1024) for s in stacks):
        raise ValueError("Missing native 1024px icon stack; an appiconset alone is insufficient")
    artwork = [entry for entry in catalog
               if entry.get("AssetType") == "Image" and entry.get("Name") == name + "_Assets/Artwork"]
    if not artwork or any(entry.get("Opaque") is not True or
                          (entry.get("PixelWidth"), entry.get("PixelHeight")) != (1024, 1024)
                          for entry in artwork):
        raise ValueError("Icon source must be an opaque, full-bleed 1024px square")
    with tempfile.TemporaryDirectory(prefix="ocloud-icon-check-") as temp:
        iconset = Path(temp) / "Fallback.iconset"
        subprocess.run(["iconutil", "--convert", "iconset", "--output", str(iconset),
                        str(resources / "OCloudSync.icns")], check=True)
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                suffix = "@2x" if scale == 2 else ""
                png = (iconset / f"icon_{size}x{size}{suffix}.png").read_bytes()
                if png[:8] != b"\x89PNG\r\n\x1a\n" or struct.unpack(">II", png[16:24]) != (size * scale,) * 2:
                    raise ValueError(f"Invalid fallback icon: {size}px at {scale}x")
    print("App icon verified: native icon stack, opaque 1024px artwork, 10 ICNS fallback sizes")


if __name__ == "__main__":
    verify(sys.argv[1])
