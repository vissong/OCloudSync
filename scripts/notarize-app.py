#!/usr/bin/env python3
"""Notarize a Developer ID signed App; credentials stay in the local Keychain."""
import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import uuid
from pathlib import Path

REQUIREMENT = "=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"


def run(argv):
    return subprocess.run(argv, check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True).stdout


def verify(app):
    for target in (app / "Contents/MacOS/OCloudLivePhoto", app):
        run(["codesign", "--verify", "--deep", "--strict", "-R", REQUIREMENT, str(target)])
        details = run(["codesign", "--display", "--verbose=2", str(target)])
        if "runtime" not in details or "Timestamp=" not in details:
            raise RuntimeError("Developer ID signing must enable hardened runtime and a secure timestamp.")


def release(app, profile, output, resume=False, keychain=None, wait_seconds=60):
    credentials = ["--keychain-profile", profile]
    if keychain:
        credentials += ["--keychain", str(keychain)]
    if not 1 <= wait_seconds <= 1800:
        raise ValueError("Wait duration must be between 1 and 1800 seconds.")
    # A fresh directory protects existing releases; resume never submits again.
    if not resume:
        output.mkdir(parents=True, exist_ok=False)
    lock = output / ".lock"
    lock.mkdir()  # Concurrent runs must not share a staging area.
    try:
        staged = output / "work/OCloudSync.app"
        submission = output / "submission.json"
        if not resume:
            if not app.is_dir() or app.name != "OCloudSync.app":
                raise RuntimeError("Expected a signed OCloudSync.app bundle.")
            verify(app)
            staged.parent.mkdir()
            shutil.copytree(app, staged, symlinks=True)
            verify(staged)
            upload = output / "work/upload.zip"
            run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(staged), str(upload)])
            # Preserve an interrupted response. Never infer that a failed upload was not accepted.
            print("Submitting signed App to Apple; waiting for a submission ID...", flush=True)
            result = run(["xcrun", "notarytool", "submit", str(upload),
                          *credentials, "--output-format", "json"])
            submission.write_text(result)
        if not submission.exists():
            raise RuntimeError("No saved submission ID. Check notarytool history before retrying an uncertain upload.")
        submission_id = str(uuid.UUID(json.loads(submission.read_text())["id"]))
        verify(staged)
        print(f"Submission: {submission_id}. Waiting up to {wait_seconds} seconds; resume if still processing.", flush=True)
        try:
            run(["xcrun", "notarytool", "wait", submission_id, *credentials,
                 "--timeout", f"{wait_seconds}s"])
        except subprocess.CalledProcessError:
            pass  # Timeout or service error: info below must independently confirm Accepted.
        result = run(["xcrun", "notarytool", "info", submission_id,
                      *credentials, "--output-format", "json"])
        (output / "status.json").write_text(result)
        status = json.loads(result)["status"]
        if status in ("Accepted", "Invalid", "Rejected"):
            run(["xcrun", "notarytool", "log", submission_id, *credentials,
                 str(output / "notary-log.json")])
        if status != "Accepted":
            raise RuntimeError(f"Notarization status: {status}. No distribution archive created. Use --resume for pending submissions.")
        run(["xcrun", "stapler", "staple", str(staged)])
        run(["xcrun", "stapler", "validate", str(staged)])
        verify(staged)
        run(["spctl", "--assess", "--type", "execute", "--verbose=2", str(staged)])
        archs = set(run(["lipo", "-archs", str(staged / "Contents/MacOS/OCloudSync")]).split())
        arch = {frozenset({"arm64"}): "arm64", frozenset({"x86_64"}): "x86_64",
                frozenset({"arm64", "x86_64"}): "universal"}.get(frozenset(archs))
        if not arch:
            raise RuntimeError("Unrecognized executable architecture.")
        archive = output / f"OCloudSync-macOS-{arch}.zip"
        pending = output / "work/distribution.zip"
        run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(staged), str(pending)])
        run(["unzip", "-tq", str(pending)])
        digest = hashlib.sha256(pending.read_bytes()).hexdigest()
        pending.replace(archive)
        (output / "SHA256SUMS").write_text(f"{digest}  {archive.name}\n")
        print(f"Notarized, stapled and Gatekeeper verified: {archive}", flush=True)
    finally:
        lock.rmdir()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="Signed App (ignored when resuming)")
    parser.add_argument("--profile", required=True, help="notarytool Keychain profile name")
    parser.add_argument("--output", required=True, type=Path, help="New output directory, or existing one with --resume")
    parser.add_argument("--resume", action="store_true", help="Wait for the saved submission; do not upload again")
    parser.add_argument("--keychain", type=Path, help="Explicit temporary keychain for CI")
    parser.add_argument("--wait-seconds", type=int, default=60, help="Apple processing wait, at most 1800 seconds")
    args = parser.parse_args()
    try:
        release(args.app.resolve(), args.profile, args.output.resolve(), args.resume, args.keychain, args.wait_seconds)
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        if isinstance(error, subprocess.CalledProcessError) and error.stdout:
            print(error.stdout, file=sys.stderr)
        print(f"Release stopped: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
