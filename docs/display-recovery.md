# Display recovery groundwork

The experimental CLI composes the offline-tested disable/recovery protocol.
TASK-12 adds read-only capture/current identity, physical-screen, driver and
lifecycle observations, but the production driver inventory remains unknown
because no complete native-only allowlist is qualified. Production private
selection therefore still refuses before writer construction. No force flag
bypasses this boundary. The commands do not qualify a private API as safe or
grant permission for a live trial. Rehearsal is deliberately verification-only.

This describes the current main-branch implementation, including the selectively
adopted [recovery foundation](recovery-reconciliation.md), not a completed disable
feature. Future direction and the
bounded identity/refusal contract are in the
[canonical implementation plan](display-disable-implementation-plan.md); execution
is tracked in `backlog/`. TASK-2 records adoption and deferred branch work. The
requirements below remain safety gates, not a mandate for open-ended identity
research or authority to call private setters.

Public [mirror/unmirror](display-mirroring.md) commands reuse this journal and
restoration engine. Mirror journals use public-only observations (no private
CoreDisplay metadata); `recovery verify` and `restore` select that same capture
path. A mirrored journal stays unresolved until the original topology is verified.

## Commands

Run from the logged-in console user's GUI session:

```sh
panelctl recovery capture
panelctl recovery status
panelctl recovery verify
panelctl recovery rehearse --timeout 5s
```

`capture` records all online displays and writes a versioned journal. `status`
prints it as JSON. `verify` compares the current configuration without changing
it. `rehearse` captures a new baseline and starts a separate verification helper,
then waits. The helper verifies on its deadline or when the parent disappears.
A successful rehearsal ends in `verified`, **not** "safe to disconnect."

An unresolved capture blocks the next capture/rehearsal: verify or restore it
first. A resolved journal is archived alongside the next capture, not deleted.
The default location is:

```text
~/Library/Application Support/PanelCtl/Recovery/current.json
```

Every action accepts `--journal <path>`. Its parent directory must be owned by
you, mode `0700`, and not a symlink. New directories are created privately.
Journals are mode `0600`. A per-user operation lock serializes recovery actions
and helpers even with different custom journals; each journal also has a lock.
Other display utilities do not participate in these locks.

### Experimental private lease (TASK-7)

```sh
panelctl recovery disable --display DISPLAY_UUID --consent-disable --timeout 15s
panelctl recovery status
panelctl recovery enable
panelctl recovery panic
```

Do not run the state-changing paths on hardware without separate scoped approval.
The current production providers refuse before constructing a disable writer
when driver inventory is unknown. A bounded identity match may be reported
eligible, but cached CG/IOKit/HPD metadata does not prove fresh physical-sink
acquisition or eliminate same-port replacement/ID-reuse risk. Fake-writer tests
exercise the transaction flow; no app UI or background disable policy is added.

Disable requires exactly one UUID, decimal/hex ID or `--index` from `panelctl list`,
affirmative `--consent-disable`, and an explicit 1–60-second timeout. No `--all`,
indefinite lease, main/built-in target, mirroring, Intel, virtual/DisplayLink driver,
or unknown physical/awake state is permitted. Selection is tied to the captured
identity; changes refuse rather than choosing a new target. The parent checks
preflight, persists the baseline and waits for READY. Only the locked helper can
stage disable, after durable intent and fresh identity/topology/lifecycle/lease
checks at every transaction boundary. `disableCommitStarted` is saved only after
final validation and before completion can run; staging alone cannot authorize
recovery after cancellation. Older staging-only journals remain preserved but
refuse private recovery. `disableCompleted` records an acknowledged completion,
separately from the staging and completion-attempt evidence needed after a crash. Setter or
completion failure must not become CLI success merely because recovery succeeded.

The foreground CLI waits for bounded recovery. Ordinary exit, SIGINT/SIGTERM and
parent death close the lease; the independent helper uses the same guarded engine
as deadline, enable, panic and stranded-intent startup recovery. Helper SIGKILL or
OS/driver failure remains unprotected. Startup recovery runs only before a new
explicit `recovery disable`, for staged disabled-by-us intent in that journal; it
never applies an unrelated public capture or changes blackout/app startup. After
successful startup recovery, the command exits 1 and requires fresh explicit
selection, avoiding index reuse after reconnection. Custom journals must be
supplied explicitly; there is no directory scan or arbitrary ID sweep.

`RecoveryPrivateSession` delivers workspace sleep/wake/session and screen-parameter
notifications on the helper run loop. Read-only lifecycle, current identity and
applicable environment observations are also refreshed synchronously at each
disable, enable and public-restoration writer boundary, as well as during the
lease. Survivor loss requests guarded recovery; it cannot relax identity.
Transitions defer writes with the fixed five-second lifecycle budget; exhaustion
preserves `needsAttention`. System re-enable is accepted with verify-only journal
reconciliation on every finish path, including EOF/signal/deadline races. Private
authority is durably closed before verification, even if layout verification fails.
The shared manual/startup engine also retires authority upon observing the retained
ID online, retaining strict identity verification but forbidding layout repair;
subsequent recovery stays verify-only. Thus
there is never a second disable or a layout write to fight the OS. This is
not a wall-clock recovery guarantee during sleep. A future production provider
must establish fresh awake/physical/driver evidence at transaction boundaries;
queued notifications alone are insufficient.

`status` prints the retained snapshot, `disabledByUsID`, staging/completion-intent/completion/one-shot
attempt evidence, `state`, `trigger` and `failure`, even if the target is absent
from inventory. It does not enumerate displays or write configuration. `enable`
and `panic` accept no selector and attempt only the journal's staged target under
the same identity checks and operation/journal locks. Panic intentionally adds no
global reset: `CGRestorePermanentDisplayConfiguration()` is an **unverified**
fallback, not an automatic response to refusal. No gamma reset, permanent commit,
DDC power or input-select write is added. Parse errors exit 2; unavailable/unsafe
operations and recovery failures exit 1. Unresolved journals remain intact.

### Manual failure ladder

1. Inspect `recovery status --journal <path>`; attempt journal `enable` only under
   the approved scope. Unknown/ambiguous identity must remain a refusal.
2. Explicit `recovery panic --journal <path>` uses the same bounded checks; it
   cannot bypass a refusal or replay an already-attempted private enable.
3. Consider a global permanent-configuration restore, logout or reboot only as
   separately approved manual actions. Their effect on the private disable flag
   is unverified; none is automatic or promised to restore the display.
4. Physical replug or a different port is a manual last resort, not a guarantee.
   Same-port replug may leave a display disabled; a changed ID/port must not be
   silently adopted as the retained target. Preserve the original journal.

Topology disable, monitor standby and input switching are distinct outcomes.
Returning a signal does not necessarily select that monitor input. Window/Spaces
placement, HDR, color/gamma and OLED maintenance are not restored or guaranteed.
Blackout remains the overlay alternative and leaves the display in the layout.

### Explicit restoration

```sh
panelctl recovery restore
```

This action **can change display configuration**, as can the timed `guard`
described below. It restores public display modes, origins, and mirroring with session scope,
then compares the result with the original snapshot. An already matching
configuration is a no-op. It never writes a permanent display configuration.

Restoration refuses missing/additional/ambiguous displays, changed numeric IDs,
changed hardware identity or connector, changed rotation or captured color-space/
ICC profile identity, another boot/OS build/user, an unavailable exact mode, or concurrent
configuration changes detected before commit. It does not search arbitrary IDs,
change power, reset firmware, restart WindowServer, delete preferences, or reboot.
Eligible ICC profiles may differ only in creation-time bytes when both snapshots
carry matching date-independent hashes; all other bytes remain protected. Legacy
journals without that evidence stay raw-hash strict. This is not general color
transform equivalence.
Restoration uses bounded read-only convergence (six observations at 200 ms
intervals), never repeated writes. A stored rehearsal `verifyOnly` flag cannot be
overridden by the restore command. Failures retain the baseline in
`needsAttention` with a diagnostic. After manual
recovery, `verify` can resolve it without a write. There is no force/discard flag.

If the OS/boot changed, verification also refuses the old journal. Keep that
journal as evidence; use a new private `--journal` location for a new baseline.
Do not edit its identity fields to bypass the guard.

### Timed public-configuration guard

```sh
panelctl recovery guard --timeout 15s
```

The CLI captures a fresh baseline, waits for the independent helper's READY
handshake, reports that it is armed, then waits. The helper runs the same restore
and verify pipeline on deadline, parent exit (including SIGKILL), or a handled
signal. It retains failures rather than repeatedly issuing writes. An unchanged
configuration needs no write.

This guard is useful groundwork, **not protection for disconnect experiments**:
if a display vanishes, recovery reports `needsAttention` rather than attempting
private reconnection. Explicit restore/guard may flicker displays or move windows.
Do not change HDR, color profiles, or rotation under this guard; they are not
restored. Another display utility can still race it. No state-changing private
call is authorized by a successful guard startup.

## What the snapshot means

Captured: OS build, boot-session UUID, user ID and host model; display UUID and
CG ID, vendor/model/serial, built-in/main/active flags, exact mode attributes
and ID, refresh rate, origin, rotation, mirror-source UUID, optional color-space
name and ICC digests, and read-only IOKit transport/type/location/HPD plus
optional CoreDisplay `IODisplayLocation`. The persisted `connector` remains the
CoreDisplay location (nil when public mirror capture omits CoreDisplay); the
new IOKit transport location is separate optional identity evidence, not a
replacement. Version-2 journals retain observation provenance and time; normal
captures carry no disabled-by-us intent. These cached fields can support only
the bounded capture/current match on the TASK-1-supported host/build and do not
prove fresh sink identity. See the [retained-ID policy](recovery-identity-policy.md)
for refusal cases and residual risks.

Not captured/restored: HDR enablement, VRR policy beyond the mode's reported
refresh rate, full color profiles/calibration, DDC brightness/power/input state,
application window placement, Spaces, or OLED maintenance state. A missing
color-space/profile identity or connector is unknown, not proof of equality or safety.
Rotation is captured/checked but not written. The current restore implementation
requires all original displays online; retained IDs are evidence, not permission
to operate on offline or recycled IDs.

## Watchdog contract

- The parent writes and synchronizes the baseline before launching a helper
  from the same executable. The helper locks the journal, verifies the baseline
  and exact mode availability without writes, arms an event-driven deadline/
  parent-pipe watcher, synchronizes `armed`, and
  sends a bounded READY handshake. Startup failures never authorize mutation.
- Foundation starts a separate process group; the helper checks isolation.
  Closing the parent lease (including parent SIGKILL) triggers early checking.
  The helper does not inherit terminal output; diagnostics live in the journal.
- Timeout is 1–60 seconds (default 5). The elapsed timer is monotonic after
  startup. Sleep can delay execution; there is no wall-clock recovery guarantee.
- `rehearse` journals have `verifyOnly: true`; the helper never calls the writer
  for them. `guard` journals use the public restoration writer. No shell-command
  hook or production identity bypass is installed. Private-lease sessions use the
  shared runtime adapter, which applies the bounded identity contract and refreshes
  read-only lifecycle/environment observations at writer boundaries. The current
  driver inventory remains unknown, so private selection refuses. The
  [bounded private lease protocol](recovery-private-lease.md) extends this same
  helper as the sole locked writer, with durable one-shot disable/recovery intent,
  fresh lease checks and bounded read-only convergence. Its synthetic tests do
  not authorize production writes. The [offline transaction backend](display-transaction-backend.md)
  is constructed only after preflight; current production observations cannot pass
  the unknown native-only driver gate.
  The internal `_recovery-helper` entry
  point is not a standalone recovery command. The recorded helper PID is for
  diagnostics only; recovery never signals a PID loaded from a journal.
- The helper cannot survive its own SIGKILL, logout, reboot, or a hung/crashed
  WindowServer/driver. Readiness is an acknowledgment, not a lifetime guarantee.

## Required before a live disable trial

1. Implement and independently qualify missing-display identification and a
   narrowly targeted re-enable backend. Do not relax current identity checks
   just to get an enable call through. An unavailable identity must block.
2. Add a mutation preflight that permits only one explicitly selected non-main
   external display and proves another usable **physical** screen remains.
   Online-count, UUID, and `builtin == false` alone do not prove this.
3. Qualify real observations for the now-connected [single-writer lease protocol](recovery-private-lease.md).
   Do not bypass the helper or treat its PID/readiness acknowledgment as lasting
   proof of health. TASK-5/TASK-7 injected tests are not hardware qualification.
4. Qualify restoration of actual hardware modes/mirroring and asynchronous
   convergence. Bounded verification may conservatively report `needsAttention`
   while macOS is still settling; it does not retry writes.
5. Address HDR/color/rotation limitations, and agree with the user on acceptable
   physical recovery (replug/reboot) before any state-changing private call.

See [the research and risk assessment](undocumented-display-control.md).

## Validation

See [TASK-8 offline acceptance](display-disable-offline-acceptance.md) for fresh
checks, the independent safety review and remaining pre-trial gates. The
[implementation validation checkpoint](recovery-validation.md) and
[reconciliation record](recovery-reconciliation.md) retain historical evidence.

`swift test --filter DisplayRecoveryTests` exercises journal locking, archives,
permissions, corruption, identity rejection, write-ahead ordering, failed writes,
verification failure, idempotence, and strict CLI parsing using fake displays.
The full `swift test` suite also exercises the existing app/CLI behavior.
The restoration pipeline is tested with a fake writer, not a live topology change.
For opt-in **no-write** subprocess checks, build the CLI and pass its path:

```sh
swift build --product panelctl
swift scripts/test-display-recovery.swift /absolute/path/to/built/panelctl
```

Use `swift build --show-bin-path` to locate it. The script tests live snapshotting,
deadline verification, parent SIGINT/SIGTERM/SIGKILL/EOF recovery, operation-lock contention,
helper SIGKILL with retained evidence, and stale-boot rejection. It never invokes `guard` or `restore`, and retains
private temporary artifacts at the printed path. It requires a GUI console session.
