#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/release-version.sh"

assert_parse() {
	local tag=$1 expected_marketing=$2 expected_full=$3 expected_prerelease=$4
	local expected_build=$5
	release_version_parse "$tag"
	[[ "$RELEASE_MARKETING_VERSION" == "$expected_marketing" ]]
	[[ "$RELEASE_FULL_VERSION" == "$expected_full" ]]
	[[ "$RELEASE_IS_PRERELEASE" == "$expected_prerelease" ]]
	[[ "$RELEASE_BUILD_NUMBER" == "$expected_build" ]]
	[[ "$RELEASE_BUILD_NUMBER" =~ ^[1-9][0-9]{0,3}\.[0-9]{1,2}\.[0-9]{1,2}$ ]]
}

assert_parse v0.3.0 0.3.0 0.3.0 0 4.0.99
assert_parse v0.3.0-alpha.2 0.3.0 0.3.0-alpha.2 1 4.0.2
assert_parse v0.3.0-beta.1 0.3.0 0.3.0-beta.1 1 4.0.31
[[ "$RELEASE_PRERELEASE" == beta.1 ]]
assert_parse v0.3.0-rc.0 0.3.0 0.3.0-rc.0 1 4.0.60
assert_parse v0.3.1-alpha.0 0.3.1 0.3.1-alpha.0 1 4.1.0
assert_parse v99.98.99 99.98.99 99.98.99 0 9999.99.99

for unsupported_tag in \
	v1 v1.2 v01.2.3 v0.3.0-preview.1 v0.3.0-beta.01 \
	v0.3.0+ci.4 v99.99.0 v0.100.0 v0.3.100 v0.3.0-rc.30; do
	if release_version_parse "$unsupported_tag"; then
		echo "expected $unsupported_tag to be rejected" >&2
		exit 1
	fi
done

# Use a disposable repository so local tags and Git configuration cannot
# influence the display-version checks. Also round-trip the bundle template.
python3 - "$(dirname "${BASH_SOURCE[0]}")/.." <<'PY'
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

root = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="panelctl-version-") as repo:
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)

    def git(*args):
        return subprocess.check_output(["git", "-C", repo, *args], env=env, text=True).strip()

    def check(tag, expected):
        actual = subprocess.check_output(
            ["bash", "-c", 'source "$1"; release_version_display "$2" "$3"',
             "bash", str(root / "scripts/release-version.sh"), repo, tag],
            env=env, text=True,
        ).strip()
        assert actual == expected, (actual, expected)
        template = (root / "Packaging/Info.plist").read_text()
        rendered = template.replace("@RELEASE_VERSION@", actual)
        rendered = rendered.replace("@MARKETING_VERSION@", "0.3.0")
        rendered = rendered.replace("@BUILD_NUMBER@", "4.0.99")
        info = plistlib.loads(rendered.encode())
        assert info["PanelCtlReleaseVersion"] == expected
        assert info["CFBundleShortVersionString"] == "0.3.0"
        assert info["CFBundleVersion"] == "4.0.99"

    git("init", "--quiet")
    git("config", "user.name", "Version Test")
    git("config", "user.email", "version@example.invalid")
    git("commit", "--quiet", "--allow-empty", "-m", "Initial")
    sha = git("rev-parse", "--short", "HEAD")
    check("v0.3.0", f"0.3.0 ({sha})")
    git("tag", "unrelated")
    check("v0.3.0", f"0.3.0 ({sha})")
    git("tag", "v0.3.0")
    check("v0.3.0", "0.3.0")
    git("tag", "-a", "v0.3.0-beta.1", "-m", "Prerelease")
    check("v0.3.0-beta.1", "0.3.0-beta.1")
    git("commit", "--quiet", "--allow-empty", "-m", "Development")
    sha = git("rev-parse", "--short", "HEAD")
    check("v0.3.0", f"0.3.0 ({sha})")
    check("v0.3.0-beta.1", f"0.3.0-beta.1 ({sha})")
    git("checkout", "--quiet", "--detach", "v0.3.0")
    check("v0.3.0", "0.3.0")
PY

echo "release version checks passed"
