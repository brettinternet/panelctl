# Development

Requires macOS 13+ and Swift 5.9+.

## Build and test

```sh
swift test --disable-sandbox
swift build --product panelctl
swift build --product PanelCtlApp
scripts/test-release-version.sh
task build:release            # universal .build/PanelCtl.app (needs https://taskfile.dev)
```

Tests use fake display writers and DDC channels; they never change real
displays. Opt-in environment variables:

| Variable | Effect |
| --- | --- |
| `PANELCTL_TEST_LIVE_BLACKOUT=1` | Run the connected-screen geometry test, which briefly covers external screens with black windows |
| `PANELCTL_ICC_EVIDENCE_DIR=<dir>` | Replay retained ICC profile artifacts (read-only); unset is a reported skip |
| `PANELCTL_SETTINGS_FIXTURE_OUTPUT=<dir>` | Write Settings PNGs (below) |
| `PANELCTL_SETTINGS_FIXTURE_WIDTH=<pt>` | Settings fixture window width; the window resizes from 440 to 680 |
| `PANELCTL_SETTINGS_FIXTURE_HEIGHT=<pt>` | Settings fixture window height |

None of these authorize private display calls or restoration trials. Recovery
no-write subprocess checks are in [display recovery](display-recovery.md#testing).

## Settings fixtures

SwiftUI builds its accessibility tree only for a connected assistive client, so
native tests reach AppKit switches and text fields; everything else is checked
through the model. Hide setup, input detection and Black out Hide all run
against fakes. To review rendered states:

```sh
mkdir -p /tmp/panelctl-settings
PANELCTL_SETTINGS_FIXTURE_OUTPUT=/tmp/panelctl-settings swift test --disable-sandbox \
  --filter 'SettingsWindowTests.test(Settings|Displays)FixtureSnapshots'
```

Don't launch the real app or enable live blackout tests for this. VoiceOver and
live monitor checks are separate, manual work.

## Release

The version in `Sources/PanelCtlCore/CLIHelp.swift` must match the tag's base
version (`1.2.3` for `v1.2.3-beta.1`).

```sh
scripts/package-release.sh v1.2.3
```

Writes universal app and CLI archives plus SHA-256 files to `dist/`. Artifacts
are ad-hoc signed, not Developer ID signed or notarized.

Cross-building Intel: SwiftPM writes to `out/Products`, so use
`swift build … --show-bin-path` rather than guessing a triple directory, and
check with `xcrun lipo -archs`.
