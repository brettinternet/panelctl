# Multi-display removal trial, 2026-10-06 UTC

## Scope and status

Supervised CLI trial on `Mac17,14`, macOS build `26A434`, initially commit
`829e2ce`. Each DDC write and each public session-scoped topology transaction
was approved separately. PanelCtl automation was snoozed for one hour; the
user confirmed presence, usable surviving displays, paused competing tools,
and monitor-button/System Settings fallback. No private setter, blackout,
global reset, logout, reboot, or automatic retry was used.

**Not qualified:** both Hides passed, but the first partial Show failed strict
origin verification. Guarded final-layout recovery succeeded, but this was not
a successful independent same-order round trip or evidence for other combinations.

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

The user separately approved one origin-only repair and a contingent DP1 input
return on `4d11d9e`. macOS again retained (3440,0); strict verification failed
and no input write ran. The same approach was stopped rather than retried.

The next recovery path recognizes the last **physically mirrored** target even
when another entry has unresolved layout recovery. Only when all other displays
are already separate can its explicit Show restore the full immutable baseline.
Unrelated or sibling mirrors refuse this path. Every pending entry remains
unresolved until full exact verification passes; only the selected target's
input callback can run. Fake tests cover the observed state, wrong-source
refusal, failed full verification retaining both entries, and successful exact
final restoration.

## Final recovery result

On `bb6c5c1`, after separate approvals for the topology and contingent input
writes, `back` of AW3425DW restored the **entire exact original baseline** in
one transaction and verified its HDMI1 return. Separate `recovery verify`
passed with journal state `verified` and both entries `restored`. A fresh
read-only capture matched all original mode IDs/rates, origins (including
S2721DGF at (3440,-4)), main flag, and absence of mirrors. S2721DGF still read
HDMI1; a separately approved DDC-only DP1 return then verified. The user
confirmed all four displays fully usable in the expected Mac arrangement.

There is no outstanding hardware recovery. The user requested retaining the
branch and continuing offline investigation rather than merging an incomplete
same-order workflow. Automation remains snoozed until the originally approved
expiry; no additional cycle is authorized.

## Offline diagnosis

The installed CoreGraphics SDK's `CGDisplayConfiguration.h` documents that
requested origins are placed as close as possible without overlap or gaps and
that origins not explicitly staged may be repositioned. It also warns that
setting a mirror follower's origin removes that display from its mirror set.
This explains why a successful transaction return alone cannot establish exact
restoration; it does **not** identify why this particular four-pixel adjustment
occurred. The partial writer staged only S2721DGF. Whether explicitly anchoring
the already-separate survivors would prevent normalization remains a hypothesis,
not a qualified fix. No private API, automatic retry, or weaker verification
is authorized by that hypothesis.

### Anchored partial-Show experiment (offline)

The next writer explicitly stages the returning S2721DGF at its exact saved
origin and the independent K272HUL/AW3423DW at their verified **current** origins,
with the unchanged main display last. No mode, origin, or mirror call is made
for AW3425DW while it remains a follower. This anchoring is limited to an
unchanged main-display coordinate frame and a non-main returning target; it
does not replay coordinates from another frame during main-display restoration.
Postverification also requires each independent anchor's exact pre-operation
mode, origin, main/activity flags and mirror relationship. Target verification,
input-return gating and final full-baseline verification remain strict. The
pending Show's pre-operation snapshot is saved before completion; reconciliation
uses the same durable anchor expectations after a crash or failed verification.
It cannot turn an anchor mismatch into success on the next inspection.

The raw recorded snapshots are retained in
`Tests/PanelCtlCoreTests/Fixtures/multi-removal-26A434.json`. Tests explicitly
model public-only capture metadata in copies, leaving both raw evidence and
runtime identity checks unchanged. `TargetRestoreTransactionTests` exercises
the production staging path through fake transaction callbacks, including
negative origins, unchanged anchors, follower exclusion, pre-commit drift,
cancel/consumption rules and mismatching postconditions. The two recorded
failed snapshots still fail verification. These tests cannot prove that
WindowServer accepts the requested layout; the experiment remains unqualified
until a separately approved cycle succeeds.
