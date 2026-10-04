# Supervised display-disable trial (TASK-9)

## Current verdict: blocked, not hardware-qualified

Preparation checkpoint: 2026-10-04, source baseline `671015c` on `main`.
No live cycle, display mutation, DDC write or disruptive fallback was performed.
No scoped human consent has been obtained. TASK-8's
[offline acceptance](display-disable-offline-acceptance.md) is not live approval.
The [canonical plan](display-disable-implementation-plan.md) governs the trial.

The technical gate also fails before any writer is constructed:

- `RecoveryPrivateSession` defaults to an inventory provider that throws
  `unsupported: no qualified fresh physical-sink binding; private display control unavailable`.
- Its physical/driver environment is unqualified and initial awake state defaults
  to false. Notifications alone do not qualify fresh mutation-boundary evidence.
- `RecoveryEnableInventory.Binding` has only unqualified, stale and synthetic
  fixture cases; none authorizes a real physical target. The default
  `RecoveryReenable` inventory also refuses offline hardware-to-CG-ID binding.

Fresh focused verification:

```sh
swift test --disable-sandbox --filter RecoveryCLITests/testProductionProviderRefusesBeforeConstructingAnyWriter
```

Result: one test passed, zero failures. It uses a fixture and asserts refusal
before writer construction even with initial awake state injected as true.
This establishes a software refusal, not present hardware identity or recovery.
No live target was selected and no new journal or helper was created.

**Resume condition:** separately scoped work must implement and independently
qualify real target identity (including while offline), physical survivor,
driver and fresh lifecycle evidence without weakening refusal. User approval
alone cannot unblock the current providers. Agree that follow-up scope before
starting it. The user approved scoping this prerequisite as TASK-11; that approval
is offline-only, not consent for a hardware cycle. Do not reopen open-ended
identity research or substitute cached
metadata, HPD, synthetic bindings or historical numeric IDs. Then obtain fresh
scoped approval for the simple cycle below. TASK-10 still depends on actual
TASK-9 input-return observations.

## TASK-11 offline checkpoint

The [provider qualification matrix](display-provider-qualification.md) records
why the production gate remains closed: no proven fresh physical acquisition,
unique absent-sink-to-retained-ID association, or replacement/context invalidation;
physical survivor/driver/initial awake and synchronous lifecycle observations also
remain unqualified. Matching the ABI host tuple does not qualify these properties.
No production authority was added. New isolated fake-writer regressions preserve
unknown environment/lifecycle and synthetic-binding refusal; they are not a live
trial. TASK-11 cannot be marked complete while provider qualification is unresolved.

Next: a separately scoped decision to defer private disable or propose a bounded,
evidence-producing investigation of a named source, with explicit permissions
and stop conditions. Do not repeatedly query cached metadata or relax guards.
Even a qualified provider would still require the fresh trial consent below.

## Trial record template — all fields pending, not approval

Complete this record with fresh evidence only after the technical gates pass.
Keep private journals/logs in their protected locations; record their paths,
not sensitive journal contents, in committed evidence.

| Before any write | Required evidence |
| --- | --- |
| Build and host | Commit/binary, architecture, host model, OS version/build, boot session |
| Selected target | Fresh UUID/retained ID, vendor/model/serial, firmware (or explicit unknown), connector, Mac input and other computer's input; non-main external, no mirroring |
| Qualified providers | Independent qualification reference and fresh target/offline-identity, physical-screen, driver, awake/lid/lifecycle results |
| Surviving screen | Exact physical display and user's confirmation it is usable; not merely an online count |
| Consent | User's exact approval, time, presence, selected target, short timeout in seconds and one disable/recovery cycle only |
| Recovery preparation | Private journal path, baseline exact modes/topology, helper READY evidence and deadline; readiness is not a recovery guarantee |
| Environment | No concurrent topology changes, other display automation or mirroring |
| Failure agreement | Accepted manual fallback and limitations; preserve journal and stop on first unexplained mismatch, no repeated toggling |

Record the actual observations, not expectations:

| Stage | Required observations |
| --- | --- |
| Disable | API/CLI result, timestamp, public enumeration, monitor signal loss/standby/no-signal message, HDMI auto-select, HPD if readable |
| Retained-ID recovery | Trigger/deadline, retained target identity evidence, driver result, signal and user-visible output, whether monitor returns to DP or stays on HDMI |
| Verification | Journal state, connectivity, topology and exact mode comparison; user confirmation of usable restored output; any mismatch and retained evidence paths |
| Limits | HDR/color, rotation, window placement and Spaces are not restored or guaranteed; note actual visible differences separately |
| Verdict | Qualified only for the tested host/OS/monitor/firmware/connection and observations, or failed/blocked with exact reason and next gate |

Global restore alone, logout, reboot, hotplug, crash and sleep trials are each
**untested and not approved**. Each needs separate explicit approval after the
simple cycle; no automatic escalation. Same-port replug is not guaranteed to
recover. DDC input selection is also untested and separately gated in TASK-10;
DDC power remains excluded. If identity refuses, retain the refusal as a blocked
result, never successful-cycle evidence.
