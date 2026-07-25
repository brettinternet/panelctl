#!/usr/bin/env bash

# Parse a release tag and derive the bundle's release and build versions.
# Callers should check the return status before using the RELEASE_* variables.
release_version_parse() {
	local tag=${1-}

	# Keep prereleases deliberately conventional so their numeric bundle
	# versions have an unambiguous increasing order.
	if [[ ! "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(alpha|beta|rc)\.(0|[1-9][0-9]*))?$ ]]; then
		return 1
	fi

	RELEASE_MAJOR=${BASH_REMATCH[1]}
	RELEASE_MINOR=${BASH_REMATCH[2]}
	RELEASE_PATCH=${BASH_REMATCH[3]}
	local prerelease_kind=${BASH_REMATCH[5]-}
	local prerelease_number=${BASH_REMATCH[6]-}

	local bundle_major
	bundle_major=$((10#$RELEASE_MAJOR * 100 + 10#$RELEASE_MINOR + 1))
	if ((10#$RELEASE_MAJOR > 99 ||
		10#$RELEASE_MINOR > 99 ||
		bundle_major > 9999 ||
		10#$RELEASE_PATCH > 99)); then
		return 1
	fi
	if [[ -n "$prerelease_number" ]] && ((10#$prerelease_number > 29)); then
		return 1
	fi

	RELEASE_MARKETING_VERSION="$RELEASE_MAJOR.$RELEASE_MINOR.$RELEASE_PATCH"
	RELEASE_FULL_VERSION=${tag#v}
	if [[ -n "$prerelease_kind" ]]; then
		RELEASE_PRERELEASE="$prerelease_kind.$prerelease_number"
		RELEASE_IS_PRERELEASE=1
	else
		RELEASE_PRERELEASE=
		RELEASE_IS_PRERELEASE=0
	fi

	# Keep each CFBundleVersion component within Apple's conservative 4.2.2
	# digit limits. Folding public major/minor into the first component keeps
	# builds ordered; the last component puts alpha < beta < rc < stable.
	local release_code=99
	case "$prerelease_kind" in
	alpha) release_code=$((10#$prerelease_number)) ;;
	beta) release_code=$((30 + 10#$prerelease_number)) ;;
	rc) release_code=$((60 + 10#$prerelease_number)) ;;
	esac
	RELEASE_BUILD_NUMBER="$bundle_major.$((10#$RELEASE_PATCH)).$release_code"
}
