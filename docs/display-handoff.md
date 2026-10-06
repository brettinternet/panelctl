# Away / back monitor handoff

`away` hides one monitor's separate Mac desktop by
[mirroring](display-mirroring.md) and optionally switches its input to another
computer. `back` Shows only the selected target and optionally selects the Mac
input. Healthy targets can share a session; the Mac keeps sending a signal and
this is not private display disable.

```sh
panelctl away --display TARGET_UUID --source SOURCE_UUID --input hdmi1 --consent-away
panelctl back --display TARGET_UUID --input dp1 --consent-back
```

- Target and source follow the [mirroring rules](display-mirroring.md). A main
  external target is accepted; macOS decides where the menu bar, Dock, windows
  and Spaces go. One main-target CLI mirror/unmirror cycle used AW3423DW onto
  AW3425DW without DDC. The handoff round trip below used a non-main target and
  main source; main-target input switching remains unqualified.
- Both accept `--journal <path>` and must use the same journal. `away` can add
  a target beside healthy removals; the session keeps its immutable baseline
  and saves each target's pre-operation topology. `back` requires an explicit
  selector (prefer the target UUID from status) and restores only that entry;
  siblings remain removed. After the
  last `back`, the exact pre-first-away arrangement, modes and main display are
  verified. It can also Show a selected target in a `mirror` session.
- `--input` is optional per command and uses the [ddc-input](ddc-input.md)
  names and codes. Omit it to make **no DDC requests**. Without DDC, switch
  inputs with the monitor's buttons: mirroring keeps the signal on, so the
  monitor won't switch by itself.

## Ordering

```text
away: validate → capture + save journal → [read input → select input] → revalidate → mirror → verify
back: bind to selected target → restore only it → verify topology → [select its input]
```

| Situation | Result |
| --- | --- |
| Capture/journal fails | No input or topology write |
| DDC channel can't open, or reports input zero | Input skipped with a monitor-button hint; hide continues |
| Current input unreadable | Hide/away skips input selection; Show/back still attempts the configured return input once |
| DDC target identity changed | Hard refusal, not a skip |
| Input write `unverified` | Away continues; check visually |
| Input write error or readback mismatch | Away stops before mirroring |
| Mirroring fails after input changed | Error prints the input switch-back command and a target-selected recovery command |
| Topology restore fails on back | No input write; selected entry and siblings stay journaled; restore command printed |
| Input fails on back | Desktop already restored; input recovery printed |

When the previous input is readable, output prints its switch-back command.
Show/back can proceed without that read after verifying topology restoration and
DDC target identity; it does not invent a previous input or recovery command.
That command is not persisted; keep the output, or use the monitor's input
button after an abrupt exit. One input write, bounded readback, no retries,
no automatic rollback, no watchdog.

Operation and journal locks cover the whole sequence. Recovery has the same
limits as mirroring: HDR, color profiles, rotation, windows and Spaces aren't
restored. For several entries, use `recovery status` then explicit
`recovery verify --display UUID` or `recovery restore --display UUID`; an
ambiguous restore refuses without replaying sibling entries.

## Returning from an inactive input

An empty HDMI input can leave the monitor black or in standby. Some monitors
stop answering DDC reads on the Mac connection in that state; this does not
establish whether they will accept an input-selection write. Show/back attempts
the known return input once even if its preliminary read fails. Failed readback
is reported as unverified, not success. If the monitor no longer accepts DDC,
use its input button to select the Mac input; PanelCtl does not wake it with
power commands or retry writes.

The reported S2721DGF empty-HDMI case (2026-10-05) failed with
`invalid payload length` before any input-selection write. The return fallback
is covered by fake-channel tests only, not a fresh hardware qualification.
Standalone `ddc-input --set` and Hide/away retain their read-first requirement.

In the later [multi-display trials](display-multi-removal-trial.md), macOS
placed S2721DGF at y=0 instead of its saved y=-4 while AW3425DW remained
mirrored. A partial `back` now accepts that placement (mode, survivors and
remaining removals still verify) and the last `back` restores the exact
original desktop. The third trial qualified that same-order cycle with input
switching; it qualifies only that tuple.

## Observed round trip, 2026-10-04

Apple M5 Max, macOS 27.0.1 `26A434`. One approved `away` and one `back`.

| Step | Result |
| --- | --- |
| Target | DELL S2721DGF, 1440×2560 @ 165 Hz, rotation 270°, HDR off |
| Source | Dell AW3423DW (main), 3440×1440 @ 175 Hz, HDR off |
| Away | Pre-read DP1 `0x0F` → selected HDMI1 `0x11` (verified) → mirror verified. Other computer's picture; no separate Mac desktop; source mode and HDR unchanged |
| Back | Topology verified → selected DP1 (verified). All four original modes, no mirrors, same main display; `recovery verify` passed |

Qualifies that single-target tuple only. Firmware and cabling weren't recorded.
Non-DDC handoff, multi-target sessions and main-target input switching are
offline-tested only. The later
[main-target mirror/unmirror cycle](display-mirroring.md#observed-main-target-cycle-2026-10-05)
did not exercise away/back or input switching. A live main-target trial requires separate scoped
approval for each mirror/restore write, recording menu bar, Dock and (0, 0)
origin behavior plus exact restoration verification.

## Tests

```sh
swift test --disable-sandbox --filter 'DisplayMirroringTests|DDCTests|CLIParserTests' -Xswiftc -warnings-as-errors
```

Fake channels cover success, omitted/unavailable/zero input, changed DDC
target, unverified selection, read and write failures on either command,
hide/unhide failure, journal creation failure and a mismatched `back` target.
