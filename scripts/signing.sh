#!/usr/bin/env bash
# Sourced by both packagers. Never fall back after a configured identity fails.

panelctl_signing_configure() {
	local required=${PANELCTL_REQUIRE_SIGNING:-0}
	PANELCTL_SIGNING_IDENTITY=${PANELCTL_SIGNING_IDENTITY:--}
	if [[ "$required" != 0 && "$required" != 1 ]]; then
		echo 'signing: PANELCTL_REQUIRE_SIGNING must be 0 or 1' >&2
		return 1
	fi
	if [[ "$PANELCTL_SIGNING_IDENTITY" == - ]]; then
		if [[ "$required" == 1 ]]; then
			echo 'signing: release requires PANELCTL_SIGNING_IDENTITY (certificate SHA-1)' >&2
			return 1
		fi
		echo 'WARNING: ad-hoc signing; privacy grants will not survive updates. Set PANELCTL_SIGNING_IDENTITY.' >&2
	elif [[ ! "$PANELCTL_SIGNING_IDENTITY" =~ ^[[:xdigit:]]{40}$ ]]; then
		echo 'signing: PANELCTL_SIGNING_IDENTITY must be the 40-character certificate SHA-1, not a name' >&2
		return 1
	fi
}

panelctl_sign() {
	local code_path=$1
	local identifier=$2
	local args=(--force --sign "$PANELCTL_SIGNING_IDENTITY" --identifier "$identifier")
	if [[ "$PANELCTL_SIGNING_IDENTITY" != - ]]; then
		# Explicit certificate pin + fixed identifier, never a per-build cdhash.
		args+=(--requirements "=designated => identifier \"$identifier\" and certificate leaf = H\"$PANELCTL_SIGNING_IDENTITY\"")
		if [[ -n "${PANELCTL_SIGNING_KEYCHAIN:-}" ]]; then
			args+=(--keychain "$PANELCTL_SIGNING_KEYCHAIN")
		fi
	fi
	codesign "${args[@]}" "$code_path"
}
