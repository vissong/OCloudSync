#!/usr/bin/env python3
import importlib.util
import base64
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
sys.dont_write_bytecode = True


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

setup = load("configure-release-secrets")
metadata = load("validate-release")
keychain = load("ci-signing-keychain")


class ReleaseCITests(unittest.TestCase):
    def test_main_only_environment(self):
        env = {"deployment_branch_policy": {"protected_branches": False, "custom_branch_policies": True}}
        setup.validate_environment(env, {"branch_policies": [{"name": "main", "type": "branch"}]})
        for policies in ([], [{"name": "*", "type": "branch"}], [{"name": "main", "type": "tag"}],
                         [{"name": "main", "type": "branch"}, {"name": "dev", "type": "branch"}]):
            with self.assertRaises(RuntimeError):
                setup.validate_environment(env, {"branch_policies": policies})

    def test_tag_must_match_app(self):
        metadata.validate_tag("v0.9.0", "0.9.0")
        for tag in ("v0.8.0", "main", "v0.9.0; touch /tmp/test", "--help", "v0.9.0\n"):
            with self.assertRaises(ValueError): metadata.validate_tag(tag, "0.9.0")

    def test_never_retarget_or_overwrite_existing_release(self):
        metadata.validate_unused("v0.9.0", [], [])
        with self.assertRaises(ValueError):
            metadata.validate_unused("v0.9.0", [{"ref": "refs/tags/v0.9.0"}], [])
        with self.assertRaises(ValueError):
            metadata.validate_unused("v0.9.0", [], [{"tag_name": "v0.9.0", "draft": True}])

    def test_select_only_developer_id_in_expected_team(self):
        identity = ' 1) ' + 'A'*40 + ' "Developer ID Application: Example (EXAMPLE123)"'
        self.assertEqual(keychain.select_identity(identity, "EXAMPLE123"), 'A'*40)
        for text in (identity, identity + "\n" + identity, identity.replace("Developer ID Application", "Apple Development")):
            with self.assertRaises(RuntimeError): keychain.select_identity(text, "OTHERTEAM0")
        with self.assertRaises(RuntimeError): keychain.select_identity(identity + "\n" + identity, "EXAMPLE123")

    def test_secret_errors_are_redacted(self):
        secret = "synthetic-password-for-test"
        failure = subprocess.CalledProcessError(1, ["security"], output="Error: " + secret)
        with patch.object(keychain.subprocess, "run", side_effect=failure):
            with self.assertRaises(RuntimeError) as error:
                keychain.run(["security", "import", secret], [secret])
        self.assertNotIn(secret, str(error.exception))

    def test_ci_import_keeps_secret_files_out_of_outputs(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            envfile = root / "github-env"
            envfile.touch()
            environment = {"GITHUB_ACTIONS": "true", "GITHUB_REF": "refs/heads/main", "RUNNER_TEMP": temp,
                           "GITHUB_ENV": str(envfile), "APPLE_CERTIFICATE_BASE64": base64.b64encode(b"synthetic").decode(),
                           "APPLE_CERTIFICATE_PASSWORD": "synthetic-p12-password", "APPLE_ID": "example@example.invalid",
                           "APPLE_APP_PASSWORD": "synthetic-app-password", "APPLE_TEAM_ID": "EXAMPLE123"}
            calls = []
            def command(argv, sensitive):
                calls.append(argv)
                if "find-identity" in argv:
                    return '1) ' + 'A'*40 + ' "Developer ID Application: Example (EXAMPLE123)"'
                return ""
            with patch.dict(keychain.os.environ, environment, clear=True), patch.object(keychain, "run", side_effect=command), patch("builtins.print"):
                keychain.setup()
            self.assertFalse((root / "OCloudSync-signing.p12").exists())
            saved = envfile.read_text()
            self.assertIn("OCLOUD_SIGN_IDENTITY=" + 'A'*40, saved)
            self.assertNotIn("synthetic-p12-password", saved)
            self.assertNotIn("synthetic-app-password", saved)
            self.assertNotIn("-A", next(c for c in calls if "import" in c))
            self.assertIn("--keychain", next(c for c in calls if "store-credentials" in c))

    def test_ci_setup_refuses_local_or_wrong_ref(self):
        with patch.dict(keychain.os.environ, {}, clear=True):
            with self.assertRaises(RuntimeError): keychain.setup()
        with patch.dict(keychain.os.environ, {"GITHUB_ACTIONS":"true", "GITHUB_REF":"refs/heads/dev"}, clear=True):
            with self.assertRaises(RuntimeError): keychain.setup()


if __name__ == "__main__": unittest.main()
