# Experimental public mirroring

`mirror` removes a display's separate desktop by mirroring it onto another
display with public CoreGraphics APIs. The Mac keeps sending a signal; gamma,
DDC and monitor input are untouched.

```sh
panelctl list
panelctl mirror --display TARGET_UUID --source SOURCE_UUID --consent-mirror
panelctl unmirror --consent-unmirror
```

| Role | Requirements |
| --- | --- |
| Target | External, not built-in, online, active, awake, with a stable identity (main is permitted) |
| Source | Explicit, distinct, online, active, awake |
| Refused | Existing mirror group, ambiguous identity, changed inventory, unavailable original mode, unresolved journal |

Both commands accept `--journal <path>` (default
`~/Library/Application Support/PanelCtl/Recovery/current.json`, shared with
[recovery](display-recovery.md)). Use the same path to unmirror. Custom parent
directories must be user-owned, mode `0700`. There is no implicit source,
startup action or automation.

## How it works

```text
mirror:   lock → capture snapshot → save journal → validate → begin
          → stage mirror → validate → complete (session scope) → verify relationship
unmirror: lock → restore captured modes, origins, mirroring, main display
          → verify against snapshot (bounded reads, one writer)
```

- Snapshots use public observations only (no private CoreDisplay metadata), so
  they cannot reconnect an absent display.
- A failed validation before completion cancels. Completion consumes the
  transaction even on error and is never followed by cancel.
- Mirror success means the relationship, source activity, identity/rotation/color
  evidence and one reported main display verify. For a non-main captured target,
  the captured main flag must remain unchanged. If the captured target was main,
  macOS may keep it main, move main to the source or report another display as
  main; that flag is exempted while the target/source relationship and all other
  existing checks remain strict. Modes and origins may change.
- The journal stays unresolved while mirrored and blocks a new capture.
  Resolved journals are archived by the next capture.

## Recovery

```sh
panelctl recovery status  [--journal <path>]   # inspect, no writes
panelctl recovery verify  [--journal <path>]   # compare, no writes
panelctl recovery restore [--journal <path>]   # restore with the same checks
```

Errors print the restore command with the actual journal path. Changed or
missing identities, rotation, color profile or unavailable modes need manual
correction first. Keep the journal. If restoration cannot be verified, turn off
mirroring and drag the menu bar back to the original display in System Settings
→ Displays, then verify the captured layout. There is no restore on exit, no
watchdog for an indefinite mirror, no global reset, and no protection from
WindowServer or driver failure.

## Side effects

- The source's resolution, refresh rate, HDR or color may change. Recovery
  restores modes, origins and mirroring, **not** HDR, color profiles, rotation,
  windows or Spaces. Color or rotation differences refuse rather than approximate.
- Cursor confinement and window migration must be observed; an API success
  says nothing about them.
- Other display apps ignore PanelCtl's advisory locks. Avoid concurrent
  topology changes.

## Trial protocol

Before writing: record build, fresh target and source UUIDs, modes/refresh/HDR,
journal path, a usable surviving screen and the manual fallback (monitor
buttons, System Settings → Displays). Don't combine DDC input changes. Stop on
the first unexplained mismatch; never repeat toggles or escalate to
logout/reboot.

### Observed cycle, 2026-10-04

Apple M5 Max, macOS 27.0.1 `26A434`. One approved mirror, then one approved
unmirror; no retries or fallback.

| | Target | Source |
| --- | --- | --- |
| Display | DELL S2721DGF | Dell AW3423DW (main) |
| Before | 1440×2560 @ 165 Hz, rotation 270°, origin (3440, −4) | 3440×1440 @ 175 Hz, HDR off, origin (0, 0) |
| Mirrored | Hardware mirror at 3440×1440 @ 165 Hz, rotation 270° | Unchanged |

| Observation | Result |
| --- | --- |
| Separate desktop removed, windows migrated | User confirmed |
| Source usable, Spaces usable | User confirmed |
| Unmirror restored arrangement, modes, main | Snapshot verification passed; separate `recovery verify` passed |

Qualifies that cycle only, not other sources, HDR on, crash/hotplug recovery or
DDC handoff.

### Observed main-target cycle, 2026-10-05

Commit `fa26adf`, Mac17,14 / macOS 27.0.1 `26A434`. User chose AW3425DW as
source, confirmed a usable survivor and manual recovery readiness, and approved
each write separately. An initial command refused at the operation lock held by
an unrelated test; no display write occurred. After that test exited, fresh
approval authorized one mirror, followed by separately approved unmirror. No
DDC, gamma, private setter, automatic retry or fallback writes occurred.

| | Target | Source |
| --- | --- | --- |
| Display | Dell AW3423DW (original main) | AW3425DW |
| UUID | `1FC57E99-DE7C-4DAF-B896-3B512CEE064F` | `A8D3635B-35EC-4171-BBE2-95FB8CF76111` |
| Before | 3440×1440 @ 175 Hz, origin (0, 0) | 3440×1440 @ 240 Hz, origin (0, 1440) |
| Transport | USB-C port 2 / DisplayPort | HDMI port 1 / DisplayPort transport |
| Mirrored | Online, inactive, not main, origin (0, 0) | Active, main, origin (0, 0) |

The mirror relationship and captured identity/rotation/color checks passed.
The user confirmed the menu bar and Dock moved to AW3425DW and it was usable
(also visible on the mirrored AW3423DW). The S2721DGF origin shifted from
(3440, −4) to (3440, 0); K272HUL stayed at (−1440, 0).

Unmirror and a separate read-only `recovery verify` passed: AW3423DW became
main again and every captured mode and origin matched, including AW3425DW at
(0, 1440) and S2721DGF at (3440, −4). The user confirmed usable output and the
menu bar/Dock back on AW3423DW. Journal
`F768EE67-6C81-46C9-93B7-3336E743D67D` remains at the default recovery path,
state `restored`.

This qualifies only this CLI mirror/unmirror cycle and observed setup, not
repeated reliability, other source combinations, app/script live paths, DDC
handoff, HDR changes, sleep or crash recovery. HDR and mirrored refresh rates
were not separately measured in this trial. Untested combinations remain
unsupported. Every future topology write still requires fresh scoped approval.

## Tests

```sh
swift test --disable-sandbox --filter DisplayMirroringTests -Xswiftc -warnings-as-errors
```

Synthetic inventories, real temporary journals and fake transactions cover
refusals, journal ordering, session-only commit, pre-completion cancel,
completion-error ownership, verification mismatch and exact-snapshot recovery.
