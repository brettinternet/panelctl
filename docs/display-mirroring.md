# Experimental public mirroring

TASK-13 provides an offline-tested alternative to private display disable. It
mirrors one non-main external target onto an explicitly selected source, removing
its separate desktop. It does **not** stop the Mac's signal, change monitor input,
blank gamma, or write DDC. The monitor can still show another computer's input if
the user selected it separately. One supervised S2721DGF → AW3423DW cycle is
recorded below; other configurations and failure recovery remain unqualified.

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

## Supervised trial protocol

Before the first mirror, record date/build, freshly discovered S2721DGF target
UUID/ID, explicit source UUID/ID, current modes/refresh/HDR, journal path, user
presence, a usable surviving screen and agreed physical/manual fallback. Obtain
approval for that exact mirror. Do not combine DDC input changes into this test;
any DDC write has its own approval requirement.

Record these observations rather than inferring them from the command result:

| Observation | Result |
| --- | --- |
| Target no longer has a separate desktop; windows migrate | User confirmed |
| Source resolution / HDR / refresh before vs after | 3440×1440 / HDR off / 175 Hz unchanged |
| Cursor movement and Spaces behavior | User confirmed no hidden desktop; Spaces usable |
| Source remains visibly usable | User confirmed |
| Freshly approved unmirror restores arrangement/modes/main | Passed exact snapshot verification |
| Recovery verify and visible restoration agree | Separate verification passed; user confirmed |

Stop on the first unexplained mismatch; retain journal/error evidence. Obtain
fresh approval for unmirror or explicit recovery fallback before executing it.
Do not repeat toggles or escalate to logout/reboot. Fake tests alone do not
qualify a hardware cycle.

### Observed cycle — 2026-10-04

Implementation `e42b28a`, Apple M5 Max, macOS 27.0.1 build 26A434. The user
approved exactly one mirror, then separately approved exactly one unmirror;
no retries, recovery fallback, DDC, gamma or private setter writes ran.

- Target: DELL S2721DGF, UUID `09084682-3C42-4455-AAB8-126A7431125B`, ID 1;
  original 1440×2560 at 165 Hz, rotation 270°, origin (3440, -4).
- Source: main Dell AW3423DW, UUID `1FC57E99-DE7C-4DAF-B896-3B512CEE064F`,
  ID 5; 3440×1440 at 175 Hz, HDR off, origin (0, 0).
- Other screens: AW3425DW 3440×1440 at 240 Hz and K272HUL 1440×2560 at
  60 Hz. The user was present with another usable screen and accepted manual
  Displays-settings correction as fallback.
- Mirror returned success and verified the relationship. System Profiler reported
  the target as a hardware mirror at 3440×1440 / 165 Hz, rotation still 270°;
  the source mode remained unchanged. Visual observations are recorded above.
- Unmirror restored the captured snapshot; a separate `recovery verify` passed
  with journal state `restored`. System Profiler confirmed all original modes,
  no mirrors, and the original main display. The user confirmed visible restoration.
- Journal `45D19BD5-13A5-4328-BAE3-E5E4196BCF6D` remains at
  `~/Library/Application Support/PanelCtl/Recovery/current.json`.

This qualifies only the observed cycle, not other sources, HDR-on operation,
crash/hotplug recovery, or a DDC handoff. Future topology writes still require
fresh scoped approval; the CLI's conservative hardware warning remains applicable
to untested configurations.

## Offline checks

`swift test --disable-sandbox --filter DisplayMirroringTests -Xswiftc -warnings-as-errors`
uses synthetic inventories, real temporary journal files and fake configuration
transactions. It covers refusal, journal ordering, session-only commit,
pre-completion invalidation/cancel, completion-error ownership, verification
mismatch and exact-snapshot recovery/failure retention. No real topology changes,
gamma, DDC or private display calls are made by these tests.
