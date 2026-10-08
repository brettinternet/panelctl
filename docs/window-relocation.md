# Window relocation contract

Contract for TASK-64 (one-shot Move windows) and TASK-65 (ongoing keep-off).
The shared direction was approved during TASK-63. TASK-64 depends on stable app
signing (TASK-66).
Neither task authorizes native window movement without
separate approval, DDC writes, or private display setters.

## 1. Saved Actions

Extend `DisplayActionEffect` with `moveWindows`. Add an optional typed
`MoveWindowsConfiguration` payload to `DisplayActionStep`, alongside the existing
`reviewedRemoval` pattern. Its required destination is `automatic` or
`display(DisplayIdentityReference)`; never persist a numeric display ID.
A Move step requires its payload; other effects reject a Move payload.

Give every step a stored UUID, independent of its target. Validate uniqueness
within an Action, and validate targets by `(lowercased UUID, effect class)`:
`blackOut`, `removeFromDesktop`, and `show` share the display-state class;
`moveWindows` has the window-move class. One display may occur once in each
class, allowing Hide + Move in either order, but not Hide + Show or two Moves.
Keep the existing 1–8 step limit and ordered, non-atomic execution.

`DisplayActionSet` becomes version 3. Read v1 single-step and v2 ordered Actions,
assign missing step UUIDs once on migration, then persist them in a new
`displayActions.v3` defaults key. Preserve the old keys as downgrade snapshots;
prefer v3 when present and never fall back from corrupt v3 to an older snapshot.
Preserve Action UUIDs, names, step order, target identities and reviewed removal
settings. Editing a target or effect retains the step UUID; adding a step creates
one. Duplicate/malformed step UUIDs invalidate that Action, not its siblings.

Decode each Action independently inside a supported envelope. An unknown effect
or invalid payload makes the *whole containing Action* unavailable, with a
visible reason; never silently drop its step and execute the rest. Preserve its
raw JSON object, including unknown fields, alongside decoded Actions when saving
other edits. Do not use a lossy decode-and-reserialize through `DisplayAction`.
A malformed/unknown envelope version keeps the original bytes and disables
editing, as today's storage-failure path does. Tests must prove that editing a
valid sibling cannot erase or enable an unsupported Action.

Existing CLI commands and Action UUID selection remain unchanged.
`alignedStepResults` keeps its index + effect + target-UUID matching behavior,
including nil for mismatched count/order; do not change existing result alignment
to depend on new step UUIDs. Clear cached results on Action edits (including
Move destination changes), so stale destination results cannot appear current.
Hide never moves windows; Move never changes hide state or installs a watcher.

## 2. Execution and public window evidence

All AX calls, including permission checks, enumeration and writes, belong to the
app process. `panelctl app run-action` uses the existing app-control route; the
standalone CLI and blackout helper never perform AX work. Only an explicit
in-app permission interaction may request Accessibility. Background and CLI
runs check without prompting and report missing/revoked permission. Do not
request Screen Recording permission or infer movability from occupancy data.

Enumerate regular running applications, excluding PanelCtl/helper and system
surfaces. Use `AXUIElementCreateApplication` and `kAXWindowsAttribute`, then
public window attributes for position, size, minimized/fullscreen state and
settable position/size. No `_AXUIElementGetWindow`, SkyLight, private Space API,
app activation, synthetic input, or Space switching.

Use the permission-free `CGWindowListCopyWindowInfo` on-screen, non-desktop
sample as a conservative *eligibility gate*, not the window source or authority
to write. Match AX windows to normal-layer visible CG entries by PID and frame
(with a documented one-point tolerance). Require a unique match in both
directions; otherwise skip as `visibility-unverified`. Never use titles to join.
This may skip indistinguishable overlapping windows; it must not guess a private
window ID. An unavailable/incomplete sample means no moves. Enumeration still
comes from each app's AX windows; occupancy alone never proves AX access. Recheck
visibility immediately before writing. Fullscreen, minimized, other-Space,
vanished and nonmovable windows receive explicit skip reasons. If public evidence
cannot distinguish other-Space from unknown visibility, use
`visibility-unverified`, not a fabricated `other-space` diagnosis.

Run AX messaging on bounded background workers, serial per target application;
never wait synchronously on the main actor, app-control listener or blackout
path. Use a 250 ms messaging timeout on *each* application/window AX element
before messaging it: the setting is per element, not inherited by all children.
After a timeout, stop contacting that app for this pass and continue other apps.
Bound each app pass to one second between calls, checking cancellation/generation
before every setter. Timed-out writes can have taken effect: report
`move-unverified`, do not blindly retry or claim a rollback. Verify frames after
writes; only verified completion increments moved. A dispatched AX call cannot
be retracted; cancellation prevents subsequent calls and discards stale results.

### Coordinates and selection

Use global logical screen coordinates with origin at the menu-bar screen's
upper-left, x rightward and y downward (AX position / CG display bounds).
Convert AppKit `NSScreen.visibleFrame` once using the menu-bar screen's full
height: `y = primaryHeight - appKitFrame.maxY`; preserve negative origins and do
not multiply by backing scale. Never substitute `NSScreen.main` (key-window
screen) for the menu-bar display when converting coordinates.

Attribute a finite, positive-area window frame to the display with the largest
positive intersection area. Resolve ties by lowercased stable display UUID;
no intersection means unattributed/skipped. This is deliberately different from
`EmptyDisplayPolicy`, where any positive overlap counts as occupancy.

Automatic chooses the current main display if eligible, otherwise ascending
lowercased stable UUID. Eligible destinations exclude source, blackout coverage
from any owner, removed, asleep, offline and mirrored-member displays. An
explicit unavailable destination refuses, never falls back. Resolve identities
strictly and revalidate topology, recovery and destination eligibility before
every write. Geometry preserves size and relative placement in destination
visible bounds, clamps to those bounds, and resizes only oversized windows;
TASK-64 owns the detailed geometry and minimum-size behavior/tests. No layout
restore is saved, and re-running ignores windows already off the source.

## 3. Honest results

Add an optional typed `windowMove` result to `AppControlActionStepResult`, with
nonnegative `moved`, `skipped`, `failed` counts and a bounded list of
`{ reason, count }` entries. Omit it for existing display effects; old results
decode without it. Do not store window titles or persistent window identifiers.
Counts refer to enumerated windows; an app that cannot be enumerated has an
`app-timeout`/`enumeration-failed` reason but no invented window count. Such an
app-level failure still prevents success even when failed-window count is zero.
Keep input fields reserved for DDC outcomes.

| Condition | Existing outcome / sequencing |
| --- | --- |
| No source windows, or all are safely skipped | `no-op`, with counts/reasons; continue |
| All eligible moves verified; ordinary skips may remain | `done`, with honest counts; continue |
| Some moves verified and a move/app fails or gate is lost | `partial`; stop later Action steps |
| No verified move and execution fails | `failed`; stop |
| Permission missing/stale, no destination, invalid identity before writes | `refused`; stop, actionable reason |
| Unresolved recovery | `recovery-needed`; stop, preserve recovery evidence |
| Safely disconnected or verified removed source | `skipped` under TASK-62; continue |
| Remaining steps after a stop | `not-run` |

A source that is blacked out is **not** unavailable for Move: moving windows
from it is the purpose. Keep TASK-62's frozen skips and strict ambiguity/recovery
refusals. Extend the aggregate's “changed” evidence to include verified window
moves, not just display changes. No-op/skipped-only Actions report Nothing to do;
existing outcome exit codes remain. No Move, prior step, or successful window is
rolled back, even when later work fails. Permission loss after verified movement
is partial rather than a misleading preflight refusal.

Stable initial reasons: `no-windows`, `source-unavailable`, `no-destination`,
`destination-unavailable`, `identity-ambiguous`, `recovery-required`,
`permission-missing`, `permission-stale`, `topology-changed`, `fullscreen`,
`minimized`, `visibility-unverified`, `vanished`, `nonmovable`, `unattributed`,
`app-timeout`, `enumeration-failed`, `move-failed`, `move-unverified`, `cancelled`.
UI, CLI JSON and status share these results; readable summaries never replace
counts with blanket success.

## 4. Keep-off ownership and lifetime

Add optional `keepWindowsOff: MoveWindowsConfiguration?` to
`DisplayHideConfiguration`: absent/nil means off; a value means opted in with
that destination. Decode old preferences as off, independently of the existing
Remove-from-desktop `enabled` setting. Hide never enables it.

One app-owned controller per strictly resolved source UUID reuses the one-shot
selector/mover. Feed it actual coverage: `AppModel.coveredHiddenDisplayIDs` for
manual/Action covers, union `ProtectionCoordinator.blackedOutDisplayIDs` for
helper-owned Automation/one-shot covers. The latter already arrives as
newline-delimited `BlackoutRuntimeStatus` through `ProtectionService.consumeStatus`
and membership callbacks. Resolve current numeric IDs against fresh identities;
saved intent, helper running state, and external power-off are not coverage.
Stopping/dead helpers, uncertain coverage, sleep or changing topology pause moves;
never treat a stale membership set alone as authority.

Membership/configuration/topology events reconcile immediately; while opted in,
a one-second clock tick reconciles state and rescans enforcing displays, covering
missed window events without requiring AX observers. At most one pass is active
per source; coalesce ticks rather than queueing passes. With healthy apps, an
eligible new window is considered within one tick plus the active pass budget
(one second per enumerated app plus one in-flight 250 ms call). This is a bounded
service delay, not a promise every app will accept a move. Publish delayed/failed
passes rather than claiming enforcement succeeded.

States: off, armed (visible), enforcing (covered and gates satisfied), paused
(reason). Show state/reason and last moved/failed counts in Displays, menu and
status stream. Automation snooze/disable does not control keep-off directly;
only resulting loss of coverage stops it. Removing the option, coverage exit or
quit cancels pending work immediately and releases timers/window references;
no new setter may start under the old generation. An already dispatched setter
may complete; never move it back. Relaunch evaluates current coverage only.

Share per-window in-flight exclusion between manual Move and keep-off, and
re-read attribution before each write. Within a session use AX element identity
and PID, not titles; release state when a window/app disappears. Back off refusal,
returning windows and suspected dragging at 1, 2, 4, 8, 16, then 30 seconds;
reset on a new enforcement session or stable success, not every tick. A pressed
mouse button plus changing geometry defers that window without synthetic input.
Recheck all gates when a retry becomes due. A missing explicit destination stays
paused; reconnect never substitutes identities.

Moves must not call the app's manual-activity hooks, reset idle timers, send input
or extend blackout. Empty-display detection continues to observe real geometry,
but PanelCtl-authored relocation must not count as new user occupancy that clears
`requiresOccupiedBeforeRearming`, nor may transient relocation samples initiate
or prolong empty-display blackout. TASK-65 must carry a session-only relocation
suppression signal to affected managed helpers before writes and acknowledge it
before proceeding: suppress empty-policy transitions for affected displays during
the pass, and do not clear a restored-display rearm latch solely from moved-window
occupancy afterward. Independent pointer/non-relocated occupancy may clear it.
Use conservative attribution; if it cannot be established, pause keep-off rather
than invent user activity. Each pass attempts at most 64 windows and revalidates
acknowledgement against the current helper set before each setter. Uncertain
writes report both possible frames and the destination to helpers. Uncertain
geometry or overflow of the helper's 256-window provenance budget disables
window-only rearming for the rest of that helper session; real pointer occupancy
still clears rearm latches. Never discard provenance and then treat the next
window sample as independent activity. This signal is not AX work in the helper and cannot
request blackout or override real input restoration, coverage exit, or time limits.
The existing physical occupancy policy must not be silently redefined as the
largest-share relocation rule. No keep-off controller starts or maintains covers.

## 5. Implementation seams and acceptance matrix

Reuse existing Action persistence, app-control results, coverage callbacks and
fake-backed app tests. Introduce only window source (AX enumeration + public
visibility evidence), window mover (set/read-back), permission provider and clock
seams; inject topology/coverage through existing app test seams. Workers must
also expose controllable pending completion for cancellation tests.

| Owner | Required fake-backed checks |
| --- | --- |
| TASK-64 persistence | v1/v2 → v3; stable Action/step UUIDs on reload/edit; same-source Hide + Move; duplicate class refusal; unknown-effect sibling survives edits; corrupt envelope preserved; result alignment/cache invalidation |
| TASK-64 selection | strict identity and recovery; automatic ordering; explicit no fallback; blacked-out source; unavailable destination; frozen source skips; topology/permission changes between setters |
| TASK-64 windows | negative origins, mixed scale, spanning/tied frames, oversized/minimum-size; unique/ambiguous CG matching; minimized/fullscreen/other-Space uncertainty, vanished and nonmovable windows |
| TASK-64 execution | no background prompt; denial/revocation; hung app does not block another; per-element timeout; timed-out write uncertainty; partial counts/exit codes/not-run; no rollback, watchers or input events |
| TASK-65 lifecycle | manual/Action/Automation entry and exit; multiple owners, one controller; armed/enforcing/paused; disable/snooze only via coverage; new/returning windows, missed ticks/events; sleep/wake, reconnect, quit/relaunch |
| TASK-65 races | coverage/config change before setter and during pending call; no stale publication; manual Move deduplicated; bounded per-window backoff/drag deferral; permission/destination recovery without prompts |
| TASK-65 policy | fake-clock cadence bound; no self-generated idle reset; helper suppression acknowledged before move; no empty-display rearm/feedback; genuine input still restores; no blackout extension |

A later window effect adds an effect case, typed payload, executor and reason
codes plus its focused tests; add an effect class only if its composition rules
require one. No generic workflow engine, new triggers, scripting or plugins.
Native validation, when separately approved, uses narrow tests gated by
`requireInteractiveUI()`; fake tests remain ungated. See [development.md](development.md).

## Evidence

TASK-63 design-time evidence: `DisplayActions.swift` (then v2 and result alignment),
`AppControlDisplayStatus.swift` (outcomes), `AppModel.swift` (storage preservation,
Action aggregation and manual coverage), `ProtectionService.swift` /
`ProtectionCoordinator.swift` (helper membership), `ProtectionPreferences.swift`
(helper arguments), and `EmptyDisplayMonitor.swift` (physical occupancy/rearm).

Public API references: [AX position coordinates](https://developer.apple.com/documentation/applicationservices/kaxpositionattribute),
[per-element messaging timeout](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout).
These API contracts are not evidence of a successful native move on this machine.
