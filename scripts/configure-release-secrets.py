#!/usr/bin/env python3
"""Interactively upload encrypted signing material to a main-only GitHub environment."""
import argparse
import base64
import getpass
import json
import subprocess
import sys
from pathlib import Path


def gh_json(*args):
    return json.loads(subprocess.run(["gh", "api", *args], check=True, capture_output=True, text=True).stdout)


def validate_environment(environment, policies):
    policy = environment.get("deployment_branch_policy") or {}
    branches = policies.get("branch_policies", [])
    if (policy.get("protected_branches") is not False or policy.get("custom_branch_policies") is not True
            or len(branches) != 1 or branches[0].get("name") != "main" or branches[0].get("type") != "branch"):
        raise RuntimeError("The release environment must allow only the main branch before uploading secrets.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--p12", required=True, type=Path)
    parser.add_argument("--repo", required=True, help="OWNER/REPO")
    parser.add_argument("--team-id", required=True)
    args = parser.parse_args()
    if not sys.stdin.isatty() or not sys.stderr.isatty():
        raise RuntimeError("Run this script in your own interactive terminal; passwords require hidden input.")
    endpoint = f"repos/{args.repo}/environments/release"
    validate_environment(gh_json(endpoint), gh_json(endpoint + "/deployment-branch-policies"))
    certificate = base64.b64encode(args.p12.expanduser().read_bytes()).decode("ascii")
    if not certificate or len(certificate) > 48000:
        raise RuntimeError("Unexpected certificate size; export only the intended identity as encrypted .p12.")
    print(f"Destination: {args.repo}, environment: release (main only)")
    password = getpass.getpass("Exported .p12 password: ")
    if not password:
        raise RuntimeError("An encrypted .p12 with a non-empty password is required.")
    result = subprocess.run(["/usr/bin/openssl", "pkcs12", "-info", "-noout", "-in",
                             str(args.p12.expanduser()), "-passin", "stdin"],
                            input=password + "\n", capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError("Cannot unlock the .p12. Check its password and file; no secrets uploaded.")
    if "Certificate bag" not in result.stderr or "Shrouded Keybag" not in result.stderr:
        raise RuntimeError("The .p12 must contain both a certificate and an encrypted private key. Export the identity from My Certificates.")
    apple_id = input("Apple account email: ").strip()
    app_password = getpass.getpass("Apple app-specific password for GitHub notarization: ")
    if not apple_id or not app_password:
        raise RuntimeError("Apple account and app-specific password are required.")
    values = {"APPLE_CERTIFICATE_BASE64": certificate, "APPLE_CERTIFICATE_PASSWORD": password,
              "APPLE_ID": apple_id, "APPLE_APP_PASSWORD": app_password, "APPLE_TEAM_ID": args.team_id}
    for name, value in values.items():
        result = subprocess.run(["gh", "secret", "set", name, "--repo", args.repo, "--env", "release"],
                                input=value, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(f"Could not save {name}. Earlier items may be saved; rerun after checking gh auth/network.")
        print(f"Saved {name}")
    print("All five release secrets saved. No private key or password was printed or written to the repository.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        # Never include subprocess arguments or output: they may contain credentials.
        message = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print(f"Setup stopped: {message}", file=sys.stderr)
        sys.exit(1)
