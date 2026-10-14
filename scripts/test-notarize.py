#!/usr/bin/env python3
"""Offline release gates: no Apple account, certificate or upload required."""
import importlib.util
import json
import subprocess
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("notarize", Path(__file__).with_name("notarize-app.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.app = self.root / "input" / "OCloudSync.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/MacOS/OCloudLivePhoto").write_text("synthetic")
        self.output = self.root / "release"
        self.calls = []
        self.status = "Accepted"
        self.adhoc = False
        self.fail_staple = False
        self.submit_failure = False

    def fake_run(self, argv, **kwargs):
        self.calls.append(argv)
        output = ""
        if argv[0] == "codesign":
            if "-R" in argv:
                self.assertTrue(argv[argv.index("-R") + 1].startswith("="), "Inline codesign requirements need an = prefix")
            if self.adhoc:
                raise subprocess.CalledProcessError(1, argv)
            if "--display" in argv:
                output = "flags=0x10000(runtime)\nTimestamp=synthetic\nTeamIdentifier=EXAMPLE\n"
        if argv[:3] == ["xcrun", "notarytool", "submit"]:
            if self.submit_failure:
                raise subprocess.CalledProcessError(1, argv)
            output = json.dumps({"id": "11111111-1111-1111-1111-111111111111"})
        if argv[:3] == ["xcrun", "notarytool", "info"]:
            output = json.dumps({"status": self.status})
        if argv[:3] == ["xcrun", "stapler", "staple"] and self.fail_staple:
            raise subprocess.CalledProcessError(1, argv)
        if argv[0] == "lipo":
            output = "arm64"
        if argv[0] == "ditto":
            Path(argv[-1]).write_bytes(b"synthetic archive")
        return subprocess.CompletedProcess(argv, 0, stdout=output)

    def execute(self, resume=False):
        with patch.object(release.subprocess, "run", side_effect=self.fake_run):
            return release.release(self.app, "test-profile", self.output, resume)

    def submitted(self):
        return sum(c[:3] == ["xcrun", "notarytool", "submit"] for c in self.calls)

    @unittest.skipUnless(shutil.which("csreq"), "Apple requirement compiler requires macOS")
    def test_requirement_compiles_with_apple_tool(self):
        subprocess.run(["csreq", "-r", release.REQUIREMENT, "-b", str(self.root / "requirement.bin")], check=True)

    def test_success_packages_only_after_staple_and_gatekeeper(self):
        self.execute()
        final = self.output / "OCloudSync-macOS-arm64.zip"
        self.assertTrue(final.exists())
        self.assertTrue((self.output / "SHA256SUMS").exists())
        gate = next(i for i,c in enumerate(self.calls) if c[0] == "spctl")
        pack = max(i for i,c in enumerate(self.calls) if c[0] == "ditto")
        self.assertLess(gate, pack)

    def test_explicit_ci_keychain_used_for_all_apple_requests(self):
        with patch.object(release.subprocess, "run", side_effect=self.fake_run):
            release.release(self.app, "ci-profile", self.output, keychain=Path("/tmp/ci.keychain-db"), wait_seconds=1200)
        for command in self.calls:
            if command[:2] == ["xcrun", "notarytool"]:
                self.assertIn("--keychain", command)
                self.assertEqual(command[command.index("--keychain") + 1], "/tmp/ci.keychain-db")
        wait = next(c for c in self.calls if c[:3] == ["xcrun", "notarytool", "wait"])
        self.assertIn("1200s", wait)

    def test_adhoc_never_uploaded(self):
        self.adhoc = True
        with self.assertRaises(subprocess.CalledProcessError): self.execute()
        self.assertEqual(self.submitted(), 0)

    def test_pending_resumes_without_second_upload(self):
        self.status = "In Progress"
        with self.assertRaises(RuntimeError): self.execute()
        self.assertFalse((self.output / "SHA256SUMS").exists())
        self.status = "Accepted"
        self.execute(resume=True)
        self.assertEqual(self.submitted(), 1)

    def test_invalid_never_packaged(self):
        self.status = "Invalid"
        with self.assertRaises(RuntimeError): self.execute()
        self.assertFalse((self.output / "SHA256SUMS").exists())
        self.assertFalse(any(c[:2] == ["xcrun", "stapler"] for c in self.calls))

    def test_staple_failure_never_packaged(self):
        self.fail_staple = True
        with self.assertRaises(subprocess.CalledProcessError): self.execute()
        self.assertFalse((self.output / "SHA256SUMS").exists())

    def test_existing_directory_not_overwritten(self):
        self.output.mkdir()
        with self.assertRaises(FileExistsError): self.execute()
        self.assertEqual(self.submitted(), 0)

    def test_unknown_upload_not_automatically_repeated(self):
        self.submit_failure = True
        with self.assertRaises(subprocess.CalledProcessError): self.execute()
        with self.assertRaises(RuntimeError): self.execute(resume=True)
        self.assertEqual(self.submitted(), 1)

if __name__ == "__main__":
    unittest.main()
