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

echo "release version checks passed"
