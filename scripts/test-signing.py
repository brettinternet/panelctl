#!/usr/bin/env python3
"""Offline signing checks: fake tools only; no certificate, TCC or UI access."""
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
IDENTITY = "0123456789ABCDEF0123456789ABCDEF01234567"

FAKE_TOOL = '''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["SIGNING_TEST_LOG"], "a") as log:
    log.write(json.dumps([name, *args]) + "\\n")
if name == "codesign":
    if os.environ.get("FAIL_SIGN") and "--sign" in args:
        sys.exit(42)
elif name == "security":
    if args[0] == "import":
        assert pathlib.Path(args[1]).read_bytes() == b"fake certificate"
    if os.environ.get("FAIL_SECURITY") == args[0]:
        print("sensitive diagnostic", file=sys.stderr)
        sys.exit(1)
elif name == "lipo":
    if "-create" in args:
        pathlib.Path(args[args.index("-output") + 1]).write_text("fake universal")
    else:
        print("arm64 x86_64")
elif name == "xcrun" and args == ["--show-sdk-version"]:
    print("15.0")
elif name == "vtool":
    print("sdk 15.0")
'''


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="panelctl-signing-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.log = self.directory / "commands.jsonl"
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("PANELCTL_SIGNING_")
                    and key != "PANELCTL_REQUIRE_SIGNING"}
        self.env.update(PATH=f"{self.directory}:{os.environ['PATH']}",
                        SIGNING_TEST_LOG=str(self.log))
        for name in ("codesign", "security", "lipo", "xcrun", "vtool"):
            tool = self.directory / name
            tool.write_text(FAKE_TOOL)
            tool.chmod(0o755)

    def run_command(self, *command):
        return subprocess.run(command, env=self.env, capture_output=True, text=True)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def sign(self):
        return self.run_command("bash", "-euc",
            'source "$1"; panelctl_signing_configure; panelctl_sign "$2" com.brettinternet.panelctl',
            "bash", str(ROOT / "scripts/signing.sh"), str(self.directory / "App with spaces.app"))

    def test_local_adhoc_warns(self):
        result = self.sign()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("WARNING: ad-hoc", result.stderr)
        self.assertEqual(self.calls()[0][3], "-")

    def test_required_missing_or_explicit_adhoc_refuses(self):
        self.env["PANELCTL_REQUIRE_SIGNING"] = "1"
        for identity in ("", "-"):
            self.env["PANELCTL_SIGNING_IDENTITY"] = identity
            self.assertNotEqual(self.sign().returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_invalid_configuration_refuses(self):
        for identity in ("PanelCtl Signing", "ABC", '"; echo injected'):
            self.env["PANELCTL_SIGNING_IDENTITY"] = identity
            self.assertNotEqual(self.sign().returncode, 0)
        self.env["PANELCTL_SIGNING_IDENTITY"] = IDENTITY
        self.env["PANELCTL_REQUIRE_SIGNING"] = "true"
        self.assertNotEqual(self.sign().returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_certificate_requirement_is_stable_and_keychain_is_scoped(self):
        self.env.update(PANELCTL_SIGNING_IDENTITY=IDENTITY,
                        PANELCTL_SIGNING_KEYCHAIN="/a path/signing.keychain-db")
        for _ in range(2):
            result = self.sign()
            self.assertEqual(result.returncode, 0, result.stderr)
        first, second = self.calls()
        self.assertEqual(first, second)
        requirement = first[first.index("--requirements") + 1]
        self.assertEqual(requirement, '=designated => identifier "com.brettinternet.panelctl" '
                         f'and certificate leaf = H"{IDENTITY}"')
        self.assertNotIn("cdhash", requirement)
        # Compile the exact literal argument with macOS, without signing or keys.
        parsed = self.run_command("/usr/bin/csreq", "-r", requirement, "-t")
        self.assertEqual(parsed.returncode, 0, parsed.stderr)
        self.assertEqual(first[first.index("--keychain") + 1], "/a path/signing.keychain-db")

    def test_signing_failure_never_falls_back(self):
        self.env.update(PANELCTL_SIGNING_IDENTITY=IDENTITY, FAIL_SIGN="1")
        self.assertEqual(self.sign().returncode, 42)
        self.assertEqual(len(self.calls()), 1)

    def package_app(self):
        binary = self.directory / "binary"
        binary.write_text("fake input")
        binary.chmod(0o755)
        return self.run_command("bash", str(ROOT / "scripts/package-app.sh"), "v0.3.0",
                                *([str(binary)] * 4), str(self.directory / "PanelCtl.app"))

    def test_app_signs_helper_before_bundle_and_verifies(self):
        self.env["PANELCTL_SIGNING_IDENTITY"] = IDENTITY
        result = self.package_app()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [call for call in self.calls() if call[0] == "codesign"]
        self.assertEqual(len(calls), 3)
        for call, identifier in zip(calls[:2], ("com.brettinternet.panelctl.cli", "com.brettinternet.panelctl")):
            self.assertEqual(call[call.index("--sign") + 1], IDENTITY)
            self.assertEqual(call[call.index("--identifier") + 1], identifier)
            self.assertIn(f'identifier "{identifier}"', call[call.index("--requirements") + 1])
        self.assertTrue(calls[0][-1].endswith("/Contents/Helpers/panelctl"))
        self.assertIn("--verify", calls[2])
        self.assertIn("--strict", calls[2])
        self.assertTrue((self.directory / "PanelCtl.app/Contents/Helpers/panelctl").exists())

    def test_packagers_fail_before_build_without_required_identity(self):
        self.env["PANELCTL_REQUIRE_SIGNING"] = "1"
        self.assertNotEqual(self.package_app().returncode, 0)
        result = self.run_command("bash", str(ROOT / "scripts/package-release.sh"), "v0.3.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("release requires", result.stderr)
        self.assertEqual(self.calls(), [])

    def import_identity(self):
        return self.run_command("python3", str(ROOT / "scripts/import-signing.py"))

    def configure_import(self):
        self.env.update(PANELCTL_SIGNING_IDENTITY=IDENTITY,
                        PANELCTL_SIGNING_P12_BASE64=base64.b64encode(b"fake certificate").decode(),
                        PANELCTL_SIGNING_P12_PASSWORD="fake password",
                        PANELCTL_SIGNING_KEYCHAIN=str(self.directory / "signing.keychain-db"))

    def test_import_missing_secrets_refuses(self):
        self.assertNotEqual(self.import_identity().returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_import_scopes_key_access_and_removes_p12(self):
        self.configure_import()
        result = self.import_identity()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertEqual([call[1] for call in calls], ["create-keychain", "set-keychain-settings",
                         "unlock-keychain", "import", "set-key-partition-list"])
        imported = calls[3]
        self.assertFalse(Path(imported[2]).exists())
        self.assertEqual(imported[-2:], ["-T", "/usr/bin/codesign"])
        self.assertNotIn("fake password", result.stdout + result.stderr)
        self.assertFalse(any("list-keychains" in call for call in calls))

    def test_import_failure_hides_diagnostics_and_removes_p12(self):
        self.configure_import()
        self.env["FAIL_SECURITY"] = "import"
        result = self.import_identity()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("sensitive diagnostic", result.stderr)
        self.assertFalse(Path(self.calls()[-1][2]).exists())

    def test_import_refuses_existing_keychain(self):
        self.configure_import()
        Path(self.env["PANELCTL_SIGNING_KEYCHAIN"]).touch()
        self.assertNotEqual(self.import_identity().returncode, 0)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
