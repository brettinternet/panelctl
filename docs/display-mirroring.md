# Experimental mirroring

`mirror` removes a display's separate desktop by mirroring it onto another
display with public macOS APIs. The Mac keeps sending a signal; brightness and
input are untouched.

```sh
panelctl list
panelctl mirror --display TARGET_UUID --source SOURCE_UUID --consent-mirror
panelctl unmirror --display TARGET_UUID --consent-unmirror
```

| Role | Requirements |
| --- | --- |
| Target | External, online, awake, stable identity (may be main) |
| Source | Explicit, different from the target, online, awake |
| Refused | Existing mirrors, ambiguous identity, unavailable original mode, unresolved recovery |

Both commands take `--journal <path>` (default
`~/Library/Application Support/PanelCtl/Recovery/current.json`). Use the same
path for both.

## How it works

```text
mirror:   lock → save layout to journal → validate → mirror → verify
unmirror: lock → restore modes, positions, mirroring, main display → verify
```

- Add more targets while existing ones are healthy. Targets can share a source
  or use different ones. A removed display can't be a source, and a source
  can't be removed until its targets are shown.
- `unmirror --display UUID` shows one target and leaves the rest removed.
  Without `--display`, it works only when one target is removed.
- While others stay removed, macOS may place the returning display slightly
  off its saved position. The last Show restores the exact original layout,
  modes and main display.
- When the target is the main display, macOS decides which display becomes
  main and where the menu bar, Dock and windows go.

## Side effects

- The source's resolution, refresh rate, HDR or color may change.
- Show restores modes, positions and mirroring, **not** HDR, color profiles,
  windows or Spaces.
- Other display apps ignore PanelCtl's locks. Don't change displays elsewhere
  at the same time.
- Nothing restores on exit. There is no watchdog for a mirror left in place.

## Recovery

```sh
panelctl recovery status                          # list removals, no writes
panelctl recovery verify --display TARGET_UUID    # check, no writes
panelctl recovery restore --display TARGET_UUID   # Show that target
```

Errors print the exact restore command. If restoring fails, turn off mirroring
in **System Settings → Displays**, drag the menu bar back to the original
display, then run `recovery verify`. See [display recovery](display-recovery.md).

## Tests

```sh
swift test --disable-sandbox --filter DisplayMirroringTests -Xswiftc -warnings-as-errors
```

Fake displays and writers cover multi-target Hide/Show orders, shared and
separate sources, main-display targets, interruptions, disconnects and exact
final restoration.
