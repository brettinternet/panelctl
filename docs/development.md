# Development

Requires macOS 13+ and Swift 5.9+.

```sh
swift test --disable-sandbox
swift build --product panelctl
swift build --product PanelCtlApp
scripts/test-release-version.sh
task build:release            # universal .build/PanelCtl.app (https://taskfile.dev)
```

Tests use fake display writers and DDC channels; they never change real
displays. Opt-in environment variables:

| Variable | Effect |
| --- | --- |
| `PANELCTL_TEST_LIVE_BLACKOUT=1` | Run a geometry test that briefly covers external screens with black windows |
| `PANELCTL_ICC_EVIDENCE_DIR=<dir>` | Replay saved ICC profiles (read-only) |
| `PANELCTL_SETTINGS_FIXTURE_OUTPUT=<dir>` | Write Settings screenshots (below) |
| `PANELCTL_DISCONNECT_FIXTURE_OUTPUT=<dir>` | Write Full disconnect screenshots |
| `PANELCTL_SETTINGS_FIXTURE_WIDTH=<pt>` / `_HEIGHT=<pt>` | Screenshot window size (width 440–680) |

Recovery checks that don't change displays are in
[display recovery](display-recovery.md#testing).

## Settings screenshots

Render Settings with fake displays, without launching the app or touching real
monitors:

```sh
mkdir -p /tmp/panelctl-settings
PANELCTL_SETTINGS_FIXTURE_OUTPUT=/tmp/panelctl-settings swift test --disable-sandbox \
  --filter 'SettingsWindowTests.test(Settings|Displays|DismissInputWarning|DisplayAction)FixtureSnapshots'
```

```sh
PANELCTL_DISCONNECT_FIXTURE_OUTPUT=/tmp/panelctl-disconnect swift test --disable-sandbox \
  --filter 'DisplayDisconnectIntegrationTests|ExperimentalDisconnectTests'
```

SwiftUI exposes its accessibility tree only to a connected assistive client,
so native UI tests drive AppKit controls and check the rest through the model.

## Release

The version in `Sources/PanelCtlCore/CLIHelp.swift` must match the tag's base
version (`1.2.3` for `v1.2.3-beta.1`).

```sh
scripts/package-release.sh v1.2.3
```

This writes universal app and CLI archives with SHA-256 files to `dist/`.
Artifacts are ad-hoc signed, not notarized.

Release builds pass the SDK to the linker (`-Xclang-linker -isysroot`).
Without it, SwiftPM can record macOS 13.0 as the SDK and macOS runs the app
with macOS 13 behavior (for example, truncated Settings rows).
`scripts/package-app.sh` refuses binaries that don't record their SDK.

When cross-building for Intel, find the output with
`swift build … --show-bin-path` and check it with `xcrun lipo -archs`.
