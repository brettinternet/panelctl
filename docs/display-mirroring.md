# Experimental public mirroring

`mirror` removes a display's separate desktop by mirroring it onto another
display with public CoreGraphics APIs. The Mac keeps sending a signal; gamma,
DDC and monitor input are untouched.

```sh
panelctl list
panelctl mirror --display TARGET_UUID --source SOURCE_UUID --consent-mirror
panelctl unmirror --display TARGET_UUID --consent-unmirror
panelctl recovery status
panelctl recovery verify --display TARGET_UUID
panelctl recovery restore --display TARGET_UUID
```

These selector examples document the multi-removal API; they do not authorize a
live write. Each hardware write still needs fresh scoped approval.

| Role | Requirements |
| --- | --- |
| Target | External, not built-in, online, active, awake, with a stable identity (main is permitted) |
| Source | Explicit, distinct, online, active, awake |
| Refused | External mirror group, ambiguous identity, changed inventory, unavailable original mode, recovery needing attention, source/target conflicts |

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
- The versioned public-mirror session stores one immutable baseline from before
  the first Hide and a separate, identified entry for each removal. Before each
  new target changes, its exact pre-operation topology is saved durably.
- `mirror` can append a target while all existing removals remain healthy and
  the observed session still matches. Several targets may share one source or
  use distinct sources. A target already removed, or a source serving another
  removed target, cannot be reused in the opposite role. Recovery needing
  attention blocks new removals.
- `unmirror --display UUID` restores only that target and leaves every other
  entry removed. Without a selector it works only when one target is unresolved;
  multiple targets are ambiguous and refuse without writing. The final Show
  strictly restores and verifies the immutable original arrangement, modes and
  main display. Any mismatch keeps recovery. Failure/interruption marks only the
  selected entry and preserves its siblings.
- A partial Show (other targets stay removed) stages only the target: clear its
  mirror, restore its mode and request its saved origin. Quartz places a
  requested origin as close as it can and may refuse the saved one while other
  displays are mirrored, so the origin is not verified. The pre-Show snapshot
  is saved first; the Show verifies exact identity, the target's mode and main
  role, that it is separate and active, that every remaining removal still
  mirrors its source and, while the main display is unchanged, that every other
  visible display kept its exact position and mode. Only then does input return
  run. The same durable expectations resolve an interrupted Show after relaunch.
  A shown target is then an ordinary visible display until the final Show.
- The journal stays unresolved while any target remains removed and blocks a
  new capture. Resolved journals are archived by the next capture.

## Partial-Show placement on the recorded layout

In two supervised S2721DGF → AW3425DW removal sequences onto AW3423DW, macOS
placed S2721DGF at (3440,0) instead of its saved (3440,-4) when it returned
while AW3425DW remained mirrored, even with the other desktops explicitly
anchored. Exact mode, survivors and the remaining mirror verified. The last
Show restored the full baseline, including (3440,-4), exactly both times.
Partial Show therefore no longer requires the saved origin (see above). The
same-order round trip with input return is not yet qualified; it needs a new
supervised trial. See [trial evidence and recovery](display-multi-removal-trial.md).

## Recovery and selectors

```sh
panelctl recovery status [--journal <path>]                        # list every entry, no writes
panelctl recovery verify --display TARGET_UUID [--journal <path>]   # verify entry/session, no Show
panelctl recovery restore --display TARGET_UUID [--journal <path>]  # Show only that target
panelctl back --display TARGET_UUID --consent-back [--journal <path>]
```

`recovery verify` and `recovery restore` may omit `--display` only when one
unresolved removal makes the target unambiguous. For several removals the CLI
refuses an omitted selector. `unmirror` and `back` accept an explicit target;
use the exact UUID from `recovery status`. Verify does not Show an active
removal. It confirms the current session. An interrupted Show resolves only by
its own durable partial-Show postcondition; a display macOS restored itself
resolves only if it matches its baseline exactly. Sibling entries are never replayed
to recover the selected target. Legacy singleton journals retain their original
commands.

Errors print a restore command with the actual journal path and explicit target
when needed. Changed or missing identities, rotation, color profile or
unavailable modes need manual correction first. Keep every session entry. If
restoration cannot be verified, turn off
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

Synthetic inventories, private temporary journals and fake writers cover
2/3-target Hide and Show permutations, shared/distinct sources, main-target
removal, macOS rearrangement, second-Hide/Show interruption, wake self-restore,
disconnection, selector ambiguity, status, legacy journals, strict verification
and exact final-baseline recovery. New combinations remain offline-only and
unqualified until separately approved live trials.
