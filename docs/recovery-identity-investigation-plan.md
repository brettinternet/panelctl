# Offline identity investigation plan — not approved for execution

## Goal and limit

Determine whether Dell-associated framebuffer/proxy objects and product metadata
survive physical sink removal, and which observed events invalidate an old
binding. This is a **negative-control experiment**, not a private re-enable
qualification. A physically absent Dell cannot be a live reconnectable sink.
Metadata that persists while its cable is visibly unplugged cannot alone prove
physical presence.

Target: DELL S2721DGF, historical CG UUID
`09084682-3c42-4455-aab8-126a7431125b`, vendor/model/serial
`4268/16857/1094800204`. IDs, paths, and entry IDs in
[the research record](recovery-offline-identity.md) are comparison evidence,
not authorization. The latest observed origin is `(3440,-4)`; no correction to
`(3440,-20)` is included.

**Observer implementation/tests and one passive stage A control are now approved.**
See the [bounded observer](recovery-identity-observer.md). Stage B physical
unplug/replug remains unapproved. Do not implement or invoke
display disabling, private enable, DDC, IOAV/user-client/link control, power/input
changes, permanent configuration, preference deletion, WindowServer termination,
or reboot. This document never authorizes a display write or physical-disconnect
experiment. Production re-enable remains blocked throughout.

## Questions and required evidence

| Question | Observation needed | Limit of the conclusion |
| --- | --- | --- |
| Does a shim represent a monitor lifetime? | Retain its handle; record path/entry ID, publication/termination and plane membership before, during, after confirmed unplug. | Persistence disproves monitor-lifetime equivalence; termination in one trial does not prove every replacement terminates it. |
| Are product attributes stale-capable? | Compare exact selected properties while the identified Dell cable is physically absent. | Persistence demonstrates stale-capable metadata. Clearing does not prove later reads are fresh hardware acquisitions. |
| Does the CG ID persist or disappear? | Bounded public/private enumeration and metadata for returned IDs only at each phase. | A retained ID is not an independent hardware binding; disappearance does not authorize looking up old or guessed IDs. |
| Does the proxy add independent identity? | Record its own properties, path, object lifetime, and events separately from the shim. | Shared controller tokens or correlated events do not bind a physical sink uniquely to a CG ID. |
| Can invalidation be missed? | Record collector readiness, callback receipt times, errors, and observer lifetime; compare events with physical operator markers and phase snapshots. | Lack of an event is not proof of continuity. Callback receipt order is not necessarily kernel/WindowServer causal order. |

The remaining positive requirement is a demonstrably fresh hardware/connector
identity uniquely bound to a CG ID **while the Dell is physically attached but
logically offline**. Physical unplug does not create that state. This plan cannot
qualify it, and does not include a private soft-disconnect experiment.

## Prerequisites before asking to execute

1. **Physical identification.** The operator identifies the Dell, exact video
   cable, monitor-side connector, and any adapter/dock. Confirm that unplugging
   that connector affects only this display, not shared USB/power/network or
   other monitors. Software `dispext3`/PortID 32 does not establish a physical
   jack label. If uncertain, do not unplug anything.
2. **Usable fallback screen.** The operator visibly confirms another physical
   screen remains usable, with access to this session and System Settings.
   CG online counts and `builtin=false` are insufficient. Confirm the original
   connector is reachable and the operator can reinsert the same cable.
3. **Accept disruption and limited recovery.** Unplugging can move windows,
   change layout/main selection/modes, and regenerate profiles. Replugging may
   not restore exact configuration or even reconnect successfully. There is no
   qualified software reconnection fallback. If this is unacceptable, stop.
4. **No competing trial.** Inspect existing recovery processes and locks; leave
   unrelated app/blackout processes untouched. The operator must arrange an idle
   display environment before proceeding; do not silently stop their utilities.
   Abort if an active recovery writer, sleep transition, or unexplained topology
   change prevents a stable baseline. No sleep/power configuration changes.
5. **Observer preparation, separately scoped.** The current snapshot diagnostic
   does not collect lifetime events. Before a live trial, implement and test a
   bounded read-only observer using the existing recovery operation lock, not a
   new lock/writer. Register public IOKit matching/termination and appropriate
   general-interest notifications, plus public CG reconfiguration callbacks.
   Drain initial matching iterators to arm them; distinguish initial inventory
   from subsequent events. Retain/release handles correctly and cap all queues,
   inventories, durations, and output. Any overflow, invalid iterator, failed
   registration, collector restart, or unavailable context makes the run
   inconclusive. Do not open a device user client or request a bus rescan.
6. **Evidence before disruption.** In a new private evidence directory, save a
   fresh recovery snapshot through existing capture/journal mechanisms, identity
   reports, and raw ICC evidence. Never overwrite/backfill an old journal.
   Preserve boot/build/user/console context and an available WindowServer process
   lifetime observation (PID alone is insufficient). Unknown context blocks the
   trial. Verify a stable baseline and exact Dell identity/origin; a mismatch with
   the proposed baseline requires a revised plan, not automatic correction.

Observer readiness acknowledges only that recording is armed. It is not
recovery readiness. Do not launch `guard`, `restore`, the origin trial, or inject
a re-enable backend. The existing watchdog refuses missing displays; a timed
check cannot physically reinsert a cable. Evidence collection can reuse existing
journal/locking infrastructure without promising restoration on parent death.

## Proposed sequence — separately approve each stage

**A. No-disruption control:** after observer implementation and offline tests,
run one 60-second passive recording with the Dell online and no requested
hardware action. Check artifacts, API failures, event initialization, bounded
termination, and clean lock release. This is not evidence of complete hotplug
event delivery. Retain the run; review it before requesting stage B approval.

**B. One physical negative control:** only after explicit approval naming the
verified cable/connector, baseline, and limitations:

1. Arm a fresh 60-second read-only recording and save the stable before snapshot.
   The operator receives a recording-ready acknowledgment before touching cables.
   Record wall-clock and monotonic timestamps plus operator phase markers.
2. The operator unplugs **only the identified video cable at the Dell end once**.
   Record the operator's confirmation of physical removal and which screen lost
   signal. Once confirmed, take one bounded offline-phase inventory; annotate
   any callbacks and additional event-triggered snapshots without unbounded
   polling. Inspect only IDs actually returned by enumeration.
3. After that capture, or after 10 seconds unplugged if capture has not completed,
   the operator reinserts the **same cable into the same connector once**. This
   planned physical return must not depend on collector or agent survival.
   Do not hold the display disconnected waiting for a software success result.
4. Record reattachment and one settled after snapshot within the recording
   window. If the window ends first, retain an incomplete result. Ask the
   operator to confirm visible output on all four physical displays. Compare
   against the fresh baseline without configuration writes. Preserve raw ICC
   changes and use only existing qualified timestamp-only comparison rules.
5. Stop the observer, release the operation lock, retain all evidence, and
   review. Do not repeat the cycle or run an enable call to improve the result.

The 60-second recording bound limits observation, **not recovery time**. The
operator's one planned cable return is the only physical recovery action in
stage B. If output fails to return, stop agent actions and ask the operator how
they wish to recover from another screen. No alternate-port attempt, repeated
replug, power cycle, automatic origin/mode correction, or escalation is included.
If another screen is unexpectedly affected, stop observation-driven actions;
the operator may still make the already-approved single same-connector return.

## Stop and interpretation rules

- Expected target removal/reappearance is the experiment, not grounds for
  bypassing identity checks. Any unrelated display change, unexpected target,
  context change, ambiguous inventory, or unexplained mismatch stops further
  investigation. Preserve both observations; do not modify baseline evidence.
- If a CG ID/path/property survives confirmed removal, label it **persistent
  metadata**, not a live sink credential. This alone rules out that proposed
  authorization signal.
- If services/IDs change on return, invalidate the old binding. Do not silently
  adopt replacements, even if the user sees the same monitor working again.
- If metadata clears and every expected event arrives, record only that this
  particular physical-unplug transition was observed. Do not infer coverage of
  logical disconnect, same-object sink replacement, ID reuse, adapters, sleep,
  WindowServer restart, boot changes, or other OS builds.
- A run with no offline CG entry, no fresh identity source, or incomplete events
  is a useful negative/inconclusive result. Keep production private enable
  blocked. Do not weaken the current strict policy to filter unknown ID 4.
- Full visible return and snapshot agreement are recovery observations for this
  physical cycle only, not emitted-color or application-window verification.

## Future approval request template — not consent

After prerequisites are satisfied, fill in the actual cable/connector, fresh
baseline, evidence directory, observer revision, and stage A results. Ask:

> May we record one 60-second read-only observation while you unplug the
> identified DELL S2721DGF video cable at [connector] once, then reinsert that
> same cable into the same connector after capture or at 10 seconds unplugged?
> Baseline: [fresh identity/origin/context]. Another physical screen [identified
> and visibly confirmed] remains available. This can move windows/change layout;
> replug may not recover output. No software restoration or private enable is
> qualified or authorized. If it fails, we stop and ask you about manual recovery.
> There will be no repeated cycle or automatic configuration correction.

Do not accept approval with placeholders unresolved. Approval for A is not
approval for B; approval for B is not approval for any private call. Hardware
replacement, alternate connectors, sleep, or logical-disconnect trials would
require new plans and separate specific approvals; none are proposed for
execution here.
