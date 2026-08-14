# Development

PanelCtl requires macOS 13 or newer and Swift 5.9 or newer.

## Build and test

```sh
swift test --disable-sandbox
swift build --product panelctl
swift build --product PanelCtlApp
scripts/test-release-version.sh
```

To build a universal `PanelCtl.app` at `.build/PanelCtl.app`, install
[Task](https://taskfile.dev/) and run:

```sh
task build:release
```

## Package a release

The version in `Sources/PanelCtlCore/CLIHelp.swift` must match the tag's base
version (for example, `1.2.3` for `v1.2.3-beta.1`).

```sh
scripts/package-release.sh vMAJOR.MINOR.PATCH
```

This creates universal app and CLI archives with SHA-256 checksum files in
`dist/`. Artifacts are ad-hoc signed, not Developer ID signed or notarized.
