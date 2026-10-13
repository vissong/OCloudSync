#!/usr/bin/env python3
"""macOS worker smoke tests using generated media only; never imports into Photos."""
import json
import pathlib
import struct
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
worker = pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="ocloud-live-test-") as temporary:
    temp = pathlib.Path(temporary)
    generator = temp / "generate"
    subprocess.run(["swiftc", str(root / "scripts/generate-motion-fixture.swift"), "-o", str(generator)], check=True, capture_output=True)
    fixture = temp / "fixture"
    subprocess.run([str(generator), str(fixture)], check=True, capture_output=True)
    source = fixture / "motion.jpg"
    # ImageIO's own JPEG writer already rounds GPS. Simulate a camera that stores
    # finer EXIF rational seconds, so the HEIC round trip exercises the regression.
    data = bytearray(source.read_bytes())
    tiff = data.index(b"Exif\0\0") + 6
    endian = {b"II": "<", b"MM": ">"}[bytes(data[tiff:tiff + 2])]
    def u16(offset):
        return struct.unpack_from(endian + "H", data, offset)[0]
    def u32(offset):
        return struct.unpack_from(endian + "I", data, offset)[0]
    def entry(ifd, tag):
        for index in range(u16(ifd)):
            offset = ifd + 2 + index * 12
            if u16(offset) == tag:
                return offset
        raise AssertionError("Missing synthetic GPS tag")
    gps = tiff + u32(entry(tiff + u32(tiff + 4), 0x8825) + 8)
    latitude = entry(gps, 2)
    assert u16(latitude + 2) == 5 and u32(latitude + 4) == 3
    struct.pack_into(endian + "6I", data, tiff + u32(latitude + 8), 1, 1, 14, 1, 4444444, 1000000)
    source.write_bytes(data)
    output = temp / "pair"
    def convert(path):
        return subprocess.run([str(worker), str(path), str(output)], capture_output=True, timeout=180)
    assert convert(source).returncode == 0, "Synthetic conversion failed"
    manifest = (output / "manifest.json").read_bytes()
    m = json.loads(manifest)
    assert m["hasAudio"] and not m["usedFallbackTime"] and m["stillTime"] == 0.85
    assert m["width"] == 128 and m["height"] == 128
    stamp = (output / "live.mov").stat().st_mtime_ns
    assert convert(source).returncode == 0
    assert manifest == (output / "manifest.json").read_bytes()
    assert stamp == (output / "live.mov").stat().st_mtime_ns, "Valid cache was not reused"
    (output / "live.mov").write_bytes(b"broken")
    assert convert(source).returncode == 0, "Corrupt cache was not regenerated"
    broken = temp / "truncated.jpg"
    broken.write_bytes(source.read_bytes()[:-50])
    assert convert(broken).returncode != 0, "Truncated motion payload was accepted"
    assert not list(temp.glob(".converting-*")), "Temporary stages leaked"
print("PASS: synthetic Live Photo, audio/timing, cache reuse, corrupt cache recovery, truncated input")
