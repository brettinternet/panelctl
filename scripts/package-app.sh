#!/usr/bin/env bash
set -euo pipefail
set -o noclobber

usage() {
	cat >&2 <<'EOF'
Usage: scripts/package-app.sh TAG ARM64_UI X86_64_UI ARM64_CLI X86_64_CLI OUTPUT_APP
EOF
}

if [[ $# -ne 6 ]]; then
	usage
	exit 2
fi

tag=$1
arm64_ui=$2
x86_64_ui=$3
arm64_cli=$4
x86_64_cli=$5
output_app=$6

source "$(dirname "${BASH_SOURCE[0]}")/release-version.sh"
if ! release_version_parse "$tag"; then
	echo "package-app.sh: tag must be a semantic version such as v1.2.3 or v1.2.3-beta.1: $tag" >&2
	exit 1
fi

marketing_version=$RELEASE_MARKETING_VERSION
build_number=$RELEASE_BUILD_NUMBER

for binary in "$arm64_ui" "$x86_64_ui" "$arm64_cli" "$x86_64_cli"; do
	if [[ ! -f "$binary" || ! -x "$binary" ]]; then
		echo "package-app.sh: executable not found: $binary" >&2
		exit 1
	fi
done

if [[ -e "$output_app" ]]; then
	echo "package-app.sh: refusing to overwrite existing output: $output_app" >&2
	exit 1
fi

output_parent=$(dirname "$output_app")
mkdir -p "$output_parent"
if [[ -e "$output_app" ]]; then
	echo "package-app.sh: refusing to overwrite existing output: $output_app" >&2
	exit 1
fi

staging=$(mktemp -d "$output_parent/.PanelCtl.app.XXXXXX")
mkdir "$staging/Contents" "$staging/Contents/MacOS" \
	"$staging/Contents/Helpers" "$staging/Contents/Resources"

lipo -create "$arm64_ui" "$x86_64_ui" -output "$staging/Contents/MacOS/PanelCtl"
lipo -create "$arm64_cli" "$x86_64_cli" -output "$staging/Contents/Helpers/panelctl"
chmod 0755 "$staging/Contents/MacOS/PanelCtl" "$staging/Contents/Helpers/panelctl"

sed \
	-e "s/@MARKETING_VERSION@/$marketing_version/g" \
	-e "s/@RELEASE_VERSION@/$RELEASE_FULL_VERSION/g" \
	-e "s/@BUILD_NUMBER@/$build_number/g" \
	"$(dirname "${BASH_SOURCE[0]}")/../Packaging/Info.plist" \
	> "$staging/Contents/Info.plist"

plutil -lint "$staging/Contents/Info.plist" >/dev/null
# Ad-hoc signing needs no Apple Developer key. Sign nested code first so
# launch-at-login and helper execution have a coherent local requirement.
codesign --force --sign - "$staging/Contents/Helpers/panelctl"
codesign --force --sign - "$staging"
codesign --verify --deep --strict "$staging"

for binary in "$staging/Contents/MacOS/PanelCtl" "$staging/Contents/Helpers/panelctl"; do
	architectures=$(lipo -archs "$binary")
	[[ "$architectures" == *arm64* && "$architectures" == *x86_64* ]]
	lipo -info "$binary"
done

mv "$staging" "$output_app"

echo "Created $output_app"
