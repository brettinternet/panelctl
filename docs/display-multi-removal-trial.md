# Multi-display removal trial, 2026-10-06 UTC

## Scope and status

Supervised CLI trial on `Mac17,14`, macOS build `26A434`, initially commit
`829e2ce`. Each DDC write and each public session-scoped topology transaction
was approved separately. PanelCtl automation was snoozed for one hour; the
user confirmed presence, usable surviving displays, paused competing tools,
and monitor-button/System Settings fallback. No private setter, blackout,
global reset, logout, reboot, or automatic retry was used.

**Not qualified:** both Hides passed, but the first partial Show failed strict
origin verification. Recovery is ongoing; do not describe this as a successful
round trip or evidence for other combinations.

## Captured baseline

| Display | UUID | Mode | Origin | Main | Mac / other input |
| --- | --- | --- | --- | --- | --- |
| DELL S2721DGF | `09084682-3c42-4455-aab8-126a7431125b` | 1440×2560 @165 Hz, mode 75, rotation 270° | (3440,-4) | No | DP1 / HDMI1 |
| AW3425DW | `a8d3635b-35ec-4171-bbe2-95fb8cf76111` | 3440×1440 @240 Hz, mode 100 | (0,1440) | No | HDMI1 / DP1 |
| Dell AW3423DW | `1fc57e99-de7c-4daf-b896-3b512cee064f` | 3440×1440 @175 Hz, mode 76 | (0,0) | Yes | Unchanged |
| K272HUL | `98402864-2a3e-4b75-92e6-0f801b89c132` | 1440×2560 @60 Hz, mode 32, rotation 270° | (-1440,0) | No | Unchanged |

Fresh IDs were respectively 1, 2, 5, 3, used only with current exact identities.
Journal: `Recovery/current.json`, session
`BC156BFD-BA21-4367-BB0D-4D06A16274D7`. The immutable baseline and each Hide's
pre-operation snapshot are retained there.

## Observations

1. `away` S2721DGF → AW3423DW, input HDMI1: mirror verified. DDC readback
   returned an invalid reply after the write, so input was reported unverified;
   the user confirmed the other computer's picture and usable Mac survivors.
2. `away` AW3425DW → AW3423DW, input DP1: DDC and mirror verified. Both
   entries separately passed `recovery verify --display UUID`. User confirmed
   both other-computer pictures, with AW3423DW and K272HUL usable on the Mac.
   Both removed targets were inactive, mirrored at (0,0). S2721DGF's mirrored
   mode was 3440×1440 @165 Hz; AW3425DW was 3440×1440 @240 Hz. Source and
   K272HUL retained their baseline modes/origins; AW3423DW remained main.
3. `back` S2721DGF, requested DP1: the target became separate and active with
   its exact original mode/rotation, but origin was (3440,0), not (3440,-4).
   Strict verification refused; **no return-input write ran**. AW3425DW stayed
   removed on the same source (observed mirrored mode 208, flags 2097155).
   Other survivors remained unchanged. S2721DGF entry became `needsAttention`;
   AW3425DW remained `mirrored`. No evidence was discarded and no write retried.

Read-only captures, command output and journal copies were retained in the
operator session under `/tmp/panelctl-task32-*` and
`/tmp/panelctl-task32-trial-evidence/`. These local paths are diagnostics, not
portable qualification artifacts. Recovery capture only records topology; it
does not change displays.

## Scoped repair

The original partial-Show path could not repair an already-unmirrored target.
The correction permits an explicit target-only layout repair for an unresolved
failed/interrupted Show only when exact session identities, every sibling mirror
relationship, and previously restored targets still verify. It changes neither
the stored baseline nor the strict target postcondition; inspection never retries
a writer. A fake regression reproduces the four-pixel mismatch, requires a
separate explicit repair, retains the sibling, refuses changed identity/sibling
topology, and withholds input return until verification succeeds.

A live repair and any later input/Show writes still need fresh separate approval.
