# panelctl

A small macOS CLI for reversible OLED blackouts, all-display sleep, display
inventory, and experimental DDC luminance control.

## Install

Build from source on macOS 13 or newer:

```sh
swift build -c release --product panelctl
install -m 0755 .build/release/panelctl ~/.local/bin/panelctl
```

Universal binaries are also published on the
[GitHub Releases page](https://github.com/brettinternet/panelctl/releases).
The standalone CLI and app are ad-hoc signed. Neither is Developer ID signed
or notarized.

### Menu-bar app

`PanelCtl.app` is a separate build that bundles the same portable `panelctl`
CLI as a supervised helper. Move it to `/Applications`, open it, choose the
displays to protect, and enable protection. The app stays out of the Dock and
provides:

- Menu-bar enable/disable and live waiting, blackout, sleep, and error state
- Per-display or explicit all-display protection using stable display UUIDs
- Configurable idle, restore, all-display sleep, and caffeinate behavior
- Launch at login, background operation, version, and project links

Closing Settings leaves protection running. Quitting the menu app stops its
watcher and removes any active blackout.

## Releases

Tagged releases include the universal `panelctl` CLI and a universal
`PanelCtl.app`. Verify the published SHA-256 checksum before running either
archive.

> [!NOTE]
> No Apple Developer Program identity is used. Releases are ad-hoc signed by
> CI, not Developer ID signed or notarized, so macOS may quarantine the app.
> Build it yourself or bypass Gatekeeper only if you trust the source and have
> verified the checksum.

If macOS blocks the app, use the supported user-facing override. Open System
Settings → Privacy & Security, scroll to Security, then click **Open Anyway**
for PanelCtl. You can also control-click `PanelCtl.app` in Finder, choose
**Open**, and confirm the dialog. Only do this after verifying the checksum and
trusting the source.

## Common uses

Indexes are the one-based values from `panelctl list` and can change after
reconnecting displays.

| Goal | Command | Result |
| --- | --- | --- |
| Inspect displays | `panelctl list` | Shows index, CG ID, UUID, model, bounds, and state |
| Black out one OLED now | `panelctl blackout --index 3 --timeout 3600` | Restores on input or after one hour |
| AFK blackout for one OLED | `panelctl blackout --index 3 --idle-after 300 --timeout 3600 --caffeinate` | Starts after five idle minutes; restores on input or after one blackout hour |
| AFK blackout, then real sleep | `panelctl blackout --index 3 --idle-after 300 --sleep-after 1800 --caffeinate` | Blacks out that panel, then sleeps every display after 30 blackout minutes |
| Repeat AFK blackout | `panelctl blackout --display <UUID> --idle-after 5m --watch` | Repeats after each fresh five-minute idle period |
| Bounded AFK blackout everywhere | `panelctl blackout --all --idle-after 300 --sleep-after 1800 --caffeinate` | Blacks out all displays, then moves all of them to real display sleep |
| Sleep displays, keep work running | `panelctl sleep-displays --keep-system-awake` | Runs `pmset displaysleepnow` while preventing idle system sleep |
| Wake displays explicitly | `panelctl wake-displays` | Declares user activity with `caffeinate -u` |
| Read DDC luminance | `panelctl ddc-luminance --display index:2` | Reads MCCS luminance VCP `0x10` |
| Set DDC luminance | `panelctl ddc-luminance --display index:2 --set 75` | Writes VCP `0x10`, then reads it back to verify |

Display selectors accept a CG ID, hexadecimal CG ID, UUID, or `index:N`.
`blackout` also accepts the clearer `--index N` shortcut and multiple targets.
Duration values accept seconds as a bare number or with an `s`, `m`, or `h`
suffix (for example, `300`, `300s`, `5m`, or `0.5h`).
Use `panelctl help` for the command list or `panelctl <command> --help` for
command-specific options.

For unattended use, prefer a UUID selector. Indexes and CG IDs are inventory
values that can change after reconnecting displays; a persisted watcher must
use the target UUID, never an index or CG ID. Explicit `--watch` targets must
also expose a UUID so the running process can follow the same physical display.

### Repeating watcher and LaunchAgent

`--watch` requires `--idle-after`. It waits for a full AFK interval, installs
the overlay, and starts a new cycle when combined-session input removes it.
`--timeout` or `--sleep-after` ends the current cycle fail-open. A signal
terminates the process; sleep, session, and display-topology interruptions reset
the current cycle. After a reset, the watcher waits for fresh input and then
another complete idle interval before installing the overlay again.
`--caffeinate` keeps an idle-sleep assertion for the entire watcher lifetime,
so a running watcher indefinitely prevents idle system sleep.

The repository includes an optional per-user LaunchAgent template at
[`examples/com.brettinternet.panelctl.blackout.plist`](examples/com.brettinternet.panelctl.blackout.plist).
Run `panelctl list`, then edit its absolute executable path and display UUID
before installing it:

```sh
mkdir -p "$HOME/Library/LaunchAgents"
cp examples/com.brettinternet.panelctl.blackout.plist \
  "$HOME/Library/LaunchAgents/com.brettinternet.panelctl.blackout.plist"
$EDITOR "$HOME/Library/LaunchAgents/com.brettinternet.panelctl.blackout.plist"
plutil -lint "$HOME/Library/LaunchAgents/com.brettinternet.panelctl.blackout.plist"
launchctl bootstrap "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/com.brettinternet.panelctl.blackout.plist"
launchctl print "gui/$(id -u)/com.brettinternet.panelctl.blackout"
launchctl bootout "gui/$(id -u)/com.brettinternet.panelctl.blackout"
```

This is a login-session example, not an installer or configuration subsystem:
`LimitLoadToSessionType Aqua` means it runs only for the logged-in user's GUI
session, and it must be bootstrapped again after editing. Keep the UUID pinned
to the intended physical display; do not replace it with `index:N` or a CG ID.
If a display has no UUID, do not persist a fallback selector.

## Blackout lifecycle

- Without `--idle-after`, blackout starts immediately.
- Any combined-session keyboard, pointer, synthetic, or remote input removes
  the blackout.
- Without `--watch`, input or `--timeout` exits; `--sleep-after` sleeps
  **every** display and then exits.
- Those two limits are mutually exclusive and begin after the blackout appears.
- `--all` requires one of those finite limits.
- `--caffeinate` uses `caffeinate -i`: it prevents idle system sleep but
  deliberately allows display sleep.
- `--watch` requires `--idle-after` and repeats after each input-ended cycle;
  timeout, display sleep, or interruption resets the cycle until fresh input
  and a new full idle interval occur.

Before showing anything, `panelctl` prepares every borderless window offscreen
and verifies that its actual frame exactly matches the current `NSScreen.frame`
and screen ID. This handles scaled, rotated, negative-origin, stacked, and large
displays in AppKit points. Any mismatch or topology change closes all blackout
windows instead of accepting partial coverage.

## Limits and safety

A pure-black window minimizes OLED pixel emission but is not hardware sleep:
the display electronics and link remain active, and the cursor, system HUD,
lock screen, or higher-level system UI may still appear. It cannot guarantee a
panel compensation cycle. For long unattended periods, use real all-display
sleep; both tested Dell OLEDs document automatic Pixel Refresh after sufficient
use when entering standby.

macOS exposes no public per-display sleep/disconnect setter. Private topology
calls can remove a display from the public inventory needed to recover it, which
is why `panelctl` does not use them. All-display sleep is intentionally global.

DDC uses private Apple Silicon IOAV/CoreDisplay transport and is
monitor-, mode-, cable-, and dock-dependent. On the tested path:

| Display | Qualification |
| --- | --- |
| AW3425DW `703CA103-…` | Read `75/100`; verified write/restore `75 → 74 → 75` |
| AW3423DW `9963A32C-…` | Communication failed; no write attempted |

`--set` is experimental and persistent; it validates against a fresh maximum,
retries verification once, and does not automatically restore the old value.
No DDC power/DPMS command is implemented.

See [docs/feasibility.md](docs/feasibility.md) for the API investigation,
displayplacer failure analysis, BetterDisplay inference, and hardware evidence.

## Development

```sh
swift test --disable-sandbox
swift build --product panelctl
swift build --product PanelCtlApp
```

CI runs tests and compiles both products on macOS. To build release archives
locally, pass a version tag to the shared packaging script:

```sh
scripts/package-release.sh v0.3.0
```

Tags matching `v*` publish universal arm64/x86_64 CLI and app archives with
SHA-256 checksums. Both artifacts are ad-hoc signed, not Developer ID signed or
notarized.
