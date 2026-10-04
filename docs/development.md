# Development

PanelCtl requires macOS 13 or newer and Swift 5.9 or newer.

## Backlog

Backlog.md is pinned in `mise.toml`. With mise installed:

```sh
mise install
mise exec -- backlog task list --plain
mise exec -- backlog task TASK-1 --plain
```

`backlog/` is the authoritative execution tracker. Update tasks through the CLI,
not by editing generated Markdown. Read `AGENTS.md` for claims and worktree rules.
The [display-disable plan](display-disable-implementation-plan.md) is the canonical
direction; TASK-1 is the recommended first bounded, offline investigation.
Hardware trials are separately approval-gated, not implied by ready dependencies.

## Build and test

```sh
swift test --disable-sandbox
swift build --product panelctl
swift build --product PanelCtlApp
scripts/test-release-version.sh
```

Routine tests use fake display writers. The connected-screen geometry test can
briefly cover external screens with opaque blackout windows; it is skipped unless
`PANELCTL_TEST_LIVE_BLACKOUT=1` is explicitly set. Leave it unset for offline
recovery acceptance. `PANELCTL_ICC_EVIDENCE_DIR` optionally enables read-only replay
of retained ICC artifacts; an unset variable is a reported skip, not qualification.
Neither opt-in authorizes private display setters or restoration trials.

For fresh offline recovery results, failure-matrix coverage and the remaining
live-trial gates, see [TASK-8 acceptance](display-disable-offline-acceptance.md).

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
