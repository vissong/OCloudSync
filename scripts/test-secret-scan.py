#!/usr/bin/env python3
"""Synthetic temporary repositories only: detect historical and staged secrets, reject shallow clones."""
import random
import string
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
scanner = root / "scripts/scan-secrets.sh"
def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout

def scan(repo, expected, staged=False):
    command = ["bash", str(scanner)] + (["--staged"] if staged else []) + [str(repo)]
    result = subprocess.run(command, capture_output=True, text=True, timeout=60)
    if result.returncode != expected:
        raise AssertionError(f"scan exit {result.returncode}, expected {expected}; output withheld")
    # The generated synthetic token must never appear in the scan output.
    assert secret not in result.stdout + result.stderr

with tempfile.TemporaryDirectory(prefix="ocloud-secret-test-") as directory:
    repo = Path(directory) / "repo"; repo.mkdir()
    git(repo, "init", "--initial-branch=main")
    git(repo, "config", "user.name", "Synthetic test")
    git(repo, "config", "user.email", "test@example.invalid")
    (repo / "README").write_text("synthetic repository\n")
    git(repo, "add", "."); git(repo, "commit", "-m", "clean fixture")
    secret = "gh" + "p_" + "".join(random.Random(2026).choices(string.ascii_letters + string.digits, k=36))
    scan(repo, 0)
    (repo / "sample.txt").write_text("credential=" + secret + "\n")
    git(repo, "add", "sample.txt")
    scan(repo, 1, staged=True)
    git(repo, "commit", "-m", "synthetic credential fixture")
    git(repo, "rm", "sample.txt"); git(repo, "commit", "-m", "remove current file")
    scan(repo, 1) # A clean HEAD must not hide a leaked credential in history.
    shallow = Path(directory) / "shallow"
    subprocess.run(["git", "clone", "--depth=1", repo.as_uri(), str(shallow)], check=True, capture_output=True)
    scan(shallow, 2)
print("PASS: full-history/staged scanning detects synthetic secrets, redacts output and rejects shallow history")
