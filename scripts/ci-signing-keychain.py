#!/usr/bin/env python3
"""Import release credentials into a temporary GitHub-hosted macOS runner keychain."""
import base64
import os
import re
import secrets
import subprocess
import sys
from pathlib import Path


def run(argv, sensitive):
    try:
        return subprocess.run(argv, check=True, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True).stdout
    except subprocess.CalledProcessError as error:
        message = error.stdout or "Command failed"
        for value in sensitive:
            if value:
                message = message.replace(value, "[REDACTED]")
        raise RuntimeError(f"{argv[0]} failed: {message}") from None


def select_identity(text, team):
    matches = re.findall(r'([A-Fa-f0-9]{40}) "Developer ID Application: [^"\n]+ \(' + re.escape(team) + r'\)"', text)
    if len(matches) != 1:
        raise RuntimeError("Expected exactly one Developer ID Application identity for the configured team.")
    return matches[0]


def setup():
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("GITHUB_REF") != "refs/heads/main":
        raise RuntimeError("This setup is restricted to GitHub Actions running on main.")
    names = ("APPLE_CERTIFICATE_BASE64", "APPLE_CERTIFICATE_PASSWORD", "APPLE_ID", "APPLE_APP_PASSWORD", "APPLE_TEAM_ID")
    values = {name: os.environ.get(name, "") for name in names}
    if not all(values.values()):
        raise RuntimeError("Missing release environment secrets; run configure-release-secrets.py locally.")
    password = secrets.token_urlsafe(40)
    sensitive = list(values.values()) + [password]
    print("::add-mask::" + password, flush=True)
    root = Path(os.environ["RUNNER_TEMP"])
    keychain = root / "OCloudSync-signing.keychain-db"
    certificate = root / "OCloudSync-signing.p12"
    if keychain.exists() or certificate.exists():
        raise RuntimeError("Temporary signing files already exist; refusing to overwrite them.")
    # Make cleanup possible even if import or validation fails partway through.
    with Path(os.environ["GITHUB_ENV"]).open("a") as env:
        env.write(f"OCLOUD_KEYCHAIN_PATH={keychain}\n")
    try:
        fd = os.open(certificate, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as destination:
            destination.write(base64.b64decode(values["APPLE_CERTIFICATE_BASE64"], validate=True))
        run(["security", "create-keychain", "-p", password, str(keychain)], sensitive)
        run(["security", "set-keychain-settings", "-lut", "21600", str(keychain)], sensitive)
        run(["security", "unlock-keychain", "-p", password, str(keychain)], sensitive)
        run(["security", "import", str(certificate), "-P", values["APPLE_CERTIFICATE_PASSWORD"],
             "-k", str(keychain), "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"], sensitive)
        run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password,
             str(keychain)], sensitive)
        identity = select_identity(run(["security", "find-identity", "-v", "-p", "codesigning", str(keychain)], sensitive),
                                   values["APPLE_TEAM_ID"])
        run(["xcrun", "notarytool", "store-credentials", "OCloudSync-release", "--keychain", str(keychain),
             "--apple-id", values["APPLE_ID"], "--team-id", values["APPLE_TEAM_ID"],
             "--password", values["APPLE_APP_PASSWORD"]], sensitive)
        with Path(os.environ["GITHUB_ENV"]).open("a") as env:
            env.write(f"OCLOUD_SIGN_IDENTITY={identity}\n")
        print("Temporary signing identity and notarization profile are ready.")
    finally:
        certificate.unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        setup()
    except (OSError, RuntimeError, ValueError, KeyError) as error:
        print(f"Signing setup stopped: {error}", file=sys.stderr)
        sys.exit(1)
