#!/usr/bin/env python3
"""macOS worker smoke tests using generated media only; never imports into Photos."""
import json
import pathlib
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
