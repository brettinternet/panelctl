# Experimental public mirroring

TASK-13 provides an offline-tested alternative to private display disable. It
mirrors one non-main external target onto an explicitly selected source, removing
its separate desktop. It does **not** stop the Mac's signal, change monitor input,
blank gamma, or write DDC. The monitor can still show another computer's input if
the user selected it separately. No hardware behavior is qualified yet.

## Commands (only after scoped human approval)

Discover fresh identities with `panelctl list`; prefer UUIDs over moving indices.
The source must be distinct, online, active and awake. The target must additionally
be non-main and not built-in. Any existing mirror group, ambiguous identity,
changed inventory, unavailable original mode or unresolved journal is refused.

```text
panelctl mirror --display <target-uuid> --source <source-uuid> --consent-mirror
panelctl unmirror --consent-unmirror
```

Both accept `--journal <path>`. Otherwise they share the existing recovery journal
at `~/Library/Application Support/PanelCtl/Recovery/current.json`. Custom parent
directories must be owned by the user, mode 0700. Use the **same path** to unmirror.
There is no implicit main-display source, startup action, or automation policy.
Each actual mirror/unmirror requires fresh scoped human approval; consent flags
are an acknowledgement, not approval inferred from a task or passing tests.

## Recovery contract

The existing RecoverySnapshot/RecoveryStore capture modes, main display, origins,
mirror relationships, public UUID/ID and vendor/model/serial, rotation and
color-space/profile evidence. Public mirror snapshots deliberately omit the
private CoreDisplay metadata query (connector is nil); mirror, unmirror and their
public recovery fallback use consistent public-only observations. This is not
private-disable identity qualification and cannot reconnect an absent display.

The shared operation and journal locks serialize with recovery writers. The
snapshot is saved durably before the public session-scoped mirror transaction.
Topology is checked again before beginning and before completion. A staging or
pre-completion validation failure cancels; completion consumes the transaction,
even on error, and is never followed by cancellation. A successful mirror is
verified by observing the target/source relationship, unchanged main display,
active source and unchanged identity/rotation/color evidence. Modes and origins
may change as a result of mirroring; success does not assert they stayed constant.

The journal remains unresolved while mirrored, blocking replacement. Unmirror
uses the existing public recovery engine to restore captured exact modes,
arrangement, mirroring and main display, then verifies (bounded read retries;
no repeated writer). Resolved journals remain available and are archived by the
next capture. Failed or interrupted attempts retain their snapshot and intent.

Inspect a failure without writes:

```text
panelctl recovery status [--journal <path>]
panelctl recovery verify [--journal <path>]
```

With explicit approval, the existing fallback is:

```text
panelctl recovery restore [--journal <path>]
```

Errors print that command with the actual journal path. It applies the same
identity and verification checks, not a bypass. Changed/missing identities,
rotation, color space/profile or unavailable modes require manual correction
first. Keep the journal; do not capture over it. There is no automatic restore on
process exit, no watchdog for this indefinite mirror operation, no global reset,
and no promise of recovery from WindowServer/driver failure. Session scope is
not an independently tested crash-recovery guarantee.

## Side effects and unsupported behavior

Mirroring can change the source's resolution, refresh rate, HDR or color state.
Public recovery restores modes/origins/mirroring, **not** HDR settings, color
profiles, rotation, windows or Spaces. Color/rotation differences cause refusal,
not silent approximation. Cursor confinement and window migration must be
observed; a successful API return is not evidence of either. Other display apps
can race the operation despite our advisory locks. Avoid concurrent topology
changes. Built-in/main targets, existing mirror groups and absent-display
reconnection are unsupported. Other monitor/OS tuples remain untested.

## Supervised trial — pending, no topology writes performed

Before the first mirror, record date/build, freshly discovered S2721DGF target
UUID/ID, explicit source UUID/ID, current modes/refresh/HDR, journal path, user
presence, a usable surviving screen and agreed physical/manual fallback. Obtain
approval for that exact mirror. Do not combine DDC input changes into this test;
any DDC write has its own approval requirement.

Record these observations rather than inferring them from the command result:

| Observation | Result |
| --- | --- |
| Target no longer has a separate desktop; windows migrate | Untested |
| Source resolution / HDR / refresh before vs after | Untested |
| Cursor movement and Spaces behavior | Untested |
| Source remains visibly usable | Untested |
| Freshly approved unmirror restores arrangement/modes/main | Untested |
| Recovery verify and visible restoration agree | Untested |

Stop on the first unexplained mismatch; retain journal/error evidence. Obtain
fresh approval for unmirror or explicit recovery fallback before executing it.
Do not repeat toggles or escalate to logout/reboot. TASK-13 AC4 remains blocked
until an approved observed cycle is recorded; fake tests do not satisfy it.

## Offline checks

`swift test --disable-sandbox --filter DisplayMirroringTests -Xswiftc -warnings-as-errors`
uses synthetic inventories, real temporary journal files and fake configuration
transactions. It covers refusal, journal ordering, session-only commit,
pre-completion invalidation/cancel, completion-error ownership, verification
mismatch and exact-snapshot recovery/failure retention. No real topology changes,
gamma, DDC or private display calls are made by these tests.
