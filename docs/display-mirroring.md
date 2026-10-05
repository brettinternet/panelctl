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
| Target | External, not built-in, online, active, awake, with a stable identity (main is permitted offline) |
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

Qualifies that cycle only, not main-target mirroring, other sources, HDR on,
crash/hotplug recovery or DDC handoff. Main-target code paths are offline-tested
only; no main-target/source combination is hardware-qualified. Any live main
target trial requires fresh approval for each write and must record where the
menu bar, Dock and (0, 0) origin go and the verified original-main restoration.

## Tests

```sh
swift test --disable-sandbox --filter DisplayMirroringTests -Xswiftc -warnings-as-errors
```

Synthetic inventories, real temporary journals and fake transactions cover
refusals, journal ordering, session-only commit, pre-completion cancel,
completion-error ownership, verification mismatch and exact-snapshot recovery.
