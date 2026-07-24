# panelctl

A small macOS CLI for reversible OLED blackouts, all-display sleep, display
inventory, and experimental DDC luminance control.

## Install

Build from source on macOS 13 or newer:

```sh
swift build -c release
install -m 0755 .build/release/panelctl ~/.local/bin/panelctl
```

Universal binaries are also published on the
[GitHub Releases page](https://github.com/brettinternet/panelctl/releases).
Release binaries are ad-hoc signed, not Developer ID signed or notarized.

## Common uses

Indexes are the one-based values from `panelctl list` and can change after
reconnecting displays.

| Goal | Command | Result |
| --- | --- | --- |
| Inspect displays | `panelctl list` | Shows index, CG ID, UUID, model, bounds, and state |
| Black out one OLED now | `panelctl blackout --index 3 --timeout 3600` | Restores on input or after one hour |
| AFK blackout for one OLED | `panelctl blackout --index 3 --idle-after 300 --timeout 3600 --caffeinate` | Starts after five idle minutes; restores on input or after one blackout hour |
| AFK blackout, then real sleep | `panelctl blackout --index 3 --idle-after 300 --sleep-after 1800 --caffeinate` | Blacks out that panel, then sleeps every display after 30 blackout minutes |
| Bounded AFK blackout everywhere | `panelctl blackout --all --idle-after 300 --sleep-after 1800 --caffeinate` | Blacks out all displays, then moves all of them to real display sleep |
| Sleep displays, keep work running | `panelctl sleep-displays --keep-system-awake` | Runs `pmset displaysleepnow` while preventing idle system sleep |
| Wake displays explicitly | `panelctl wake-displays` | Declares user activity with `caffeinate -u` |
| Read DDC luminance | `panelctl ddc-luminance --display index:2` | Reads MCCS luminance VCP `0x10` |
| Set DDC luminance | `panelctl ddc-luminance --display index:2 --set 75` | Writes VCP `0x10`, then reads it back to verify |

Display selectors accept a CG ID, hexadecimal CG ID, UUID, or `index:N`.
`blackout` also accepts the clearer `--index N` shortcut and multiple targets.

## Blackout lifecycle

- Without `--idle-after`, blackout starts immediately.
- Any combined-session keyboard, pointer, synthetic, or remote input removes
  the blackout and exits; the command is one-shot.
- `--timeout` removes the blackout and exits.
- `--sleep-after` removes the blackout and then sleeps **every** display.
- Those two limits are mutually exclusive and begin after the blackout appears.
- `--all` requires one of those finite limits.
- `--caffeinate` uses `caffeinate -i`: it prevents idle system sleep but
  deliberately allows display sleep.

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
```

CI runs the tests on macOS. Tags matching `v*` build and publish an ad-hoc
signed universal arm64/x86_64 release with a SHA-256 checksum.
