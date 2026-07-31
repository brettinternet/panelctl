#!/usr/bin/env bash
set -euo pipefail
set -o noclobber

usage() {
	cat >&2 <<'EOF'
Usage: scripts/package-release.sh TAG [OUTPUT_DIR]

Builds arm64 and x86_64 release products, then creates universal CLI and
PanelCtl.app archives with SHA-256 checksums.
EOF
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
	usage
	exit 2
fi

tag=$1
output_dir=${2:-dist}
source "$(dirname "${BASH_SOURCE[0]}")/release-version.sh"
if ! release_version_parse "$tag"; then
	echo "package-release.sh: tag must be a semantic version such as v1.2.3 or v1.2.3-beta.1: $tag" >&2
	exit 1
fi
marketing_version=$RELEASE_MARKETING_VERSION

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_version=$(
	sed -n 's/.*public static let version = "panelctl \([^"]*\)".*/\1/p' \
		"$repo_root/Sources/PanelCtlCore/CLIHelp.swift"
)
if [[ "$source_version" != "$marketing_version" ]]; then
	echo "package-release.sh: tag $tag does not match panelctl $source_version" >&2
	exit 1
fi
output_dir=$(mkdir -p "$output_dir" && cd "$output_dir" && pwd)
cli_archive="panelctl-cli-${tag}-macos-universal.zip"
app_archive="PanelCtl-${tag}-macos-universal.zip"
for output in "$output_dir/$cli_archive" "$output_dir/$cli_archive.sha256" \
	"$output_dir/$app_archive" "$output_dir/$app_archive.sha256"; do
	if [[ -e "$output" ]]; then
		echo "package-release.sh: refusing to overwrite existing output: $output" >&2
		exit 1
	fi
done

arm64_scratch="$repo_root/.build/package-release-arm64"
x86_64_scratch="$repo_root/.build/package-release-x86_64"

build_product() {
	local product=$1
	local triple=$2
	local scratch=$3
	swift build --disable-sandbox --configuration release --product "$product" \
		--triple "$triple" --scratch-path "$scratch"
}

build_product PanelCtlApp arm64-apple-macosx13.0 "$arm64_scratch"
build_product panelctl arm64-apple-macosx13.0 "$arm64_scratch"
build_product PanelCtlApp x86_64-apple-macosx13.0 "$x86_64_scratch"
build_product panelctl x86_64-apple-macosx13.0 "$x86_64_scratch"

find_binary() {
	local scratch=$1
	local product=$2
	find "$scratch" -type f -path "*/release/$product" -perm -111 -print -quit
}

arm64_ui=$(find_binary "$arm64_scratch" PanelCtlApp)
x86_64_ui=$(find_binary "$x86_64_scratch" PanelCtlApp)
arm64_cli=$(find_binary "$arm64_scratch" panelctl)
x86_64_cli=$(find_binary "$x86_64_scratch" panelctl)
for binary in "$arm64_ui" "$x86_64_ui" "$arm64_cli" "$x86_64_cli"; do
	if [[ -z "$binary" ]]; then
		echo "package-release.sh: failed to locate a release executable" >&2
		exit 1
	fi
done

universal_staging=$(mktemp -d "${TMPDIR:-/tmp}/panelctl-release.XXXXXX")
cleanup() {
	if [[ -x /usr/bin/trash && -e "$universal_staging" ]]; then
		/usr/bin/trash "$universal_staging" || true
	fi
}
trap cleanup EXIT

lipo -create "$arm64_cli" "$x86_64_cli" -output "$universal_staging/panelctl"
chmod 0755 "$universal_staging/panelctl"
codesign --force --sign - "$universal_staging/panelctl"
codesign --verify --strict "$universal_staging/panelctl"
lipo -info "$universal_staging/panelctl"

zip -q -j "$output_dir/$cli_archive" \
	"$universal_staging/panelctl" "$repo_root/README.md"
(
	cd "$repo_root"
	zip -q "$output_dir/$cli_archive" examples/com.brettinternet.panelctl.blackout.plist
)
(
	cd "$output_dir"
	shasum -a 256 "$cli_archive" > "$cli_archive.sha256"
)

"$repo_root/scripts/package-app.sh" "$tag" "$arm64_ui" "$x86_64_ui" "$arm64_cli" "$x86_64_cli" \
	"$universal_staging/PanelCtl.app"
app_archive_staging="$universal_staging/archive"
mkdir "$app_archive_staging"
ditto "$universal_staging/PanelCtl.app" "$app_archive_staging/PanelCtl.app"
cp "$repo_root/README.md" "$app_archive_staging/"
ditto -c -k --sequesterRsrc "$app_archive_staging" "$output_dir/$app_archive"
(
	cd "$output_dir"
	shasum -a 256 "$app_archive" > "$app_archive.sha256"
)

echo "Created $output_dir/$cli_archive"
echo "Created $output_dir/$app_archive"
