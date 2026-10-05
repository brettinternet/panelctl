# Supervised display-disable trial (TASK-9)

## Current verdict: blocked, not hardware-qualified

Preparation checkpoint: 2026-10-05, offline provider implementation on `main`.
No live cycle, display mutation, DDC write or disruptive fallback was performed.
No scoped human consent has been obtained. TASK-8's
[offline acceptance](display-disable-offline-acceptance.md) is not live approval.
The [canonical plan](display-disable-implementation-plan.md) governs the trial.

The technical gate still fails before any writer is constructed. The production
identity provider returned an exact supported-host capture/current match in the
no-write rehearsal, and read-only IOKit/CG observations classified connected
external candidates and a survivor. The production driver provider found no
recognized prohibited service name but cannot prove a complete native-only
driver inventory, so it reports `unknown`; every target is refused with
`DisplayLink, virtual or unknown driver state`. Production refusal remains
strict. Cached identity limitations (same-port replacement and reused IDs) are
documented in the [identity policy](recovery-identity-policy.md).

Fresh focused verification:

```sh
swift test --disable-sandbox --filter 'RecoveryProductionProviderTests'
```

Result: rehearsal passed with no writer construction and exact candidate/survivor
observations recorded in the [provider qualification matrix](display-provider-qualification.md).
No private setter, public restore, DDC operation, helper arming or topology
change was performed. No live target was selected and no new journal/helper was
created.

**Resume condition:** independently qualify a complete native-only driver
inventory, address the documented identity residual risks or explicitly accept
the bounded plan contract for the specific setup, then obtain fresh scoped
approval for the simple cycle below. Approval alone cannot bypass a technical
gate. No DCP investigation or hardware write is authorized by this record.
TASK-10 still depends on actual TASK-9 input-return observations.

## TASK-11 historical offline checkpoint

TASK-11's 2026-10-04 assessment found the production inventory and environment
seams refusing by default under the earlier fresh-sink-binding contract.
TASK-12 later implemented the canonical bounded capture/current contract and
real read-only observations. The remaining provider gate is the unknown complete
native-only driver inventory. The identity policy documents cached-metadata,
same-port replacement and ID-reuse risks. TASK-11/TASK-12 fake-writer tests do
not qualify hardware. Do not repeatedly query cached metadata or relax guards.
Even a qualified provider still requires the fresh trial consent below.

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
