# Offline identity: read-only lifetime investigation

## Decision

**Source-contract investigation complete; private re-enable parked.** See the
[three-part interface verdict](recovery-identity-contract.md). No candidate
establishes all required contracts; no physical-unplug or observer follow-up is
proposed. Historical observations below are not current qualification.

**Private re-enable remains blocked.** A live IORegistry object is not proof of
live monitor identity. No production provider, journal migration, or display
write is justified by the current evidence. DELL S2721DGF has not been observed
offline during this investigation; no disconnected state was manufactured.

## Connector-binding follow-up (2026-10-02)

[SDK and pinned implementation research](recovery-connector-binding.md) found no
qualified independent fresh offline binding. Public IODisplay info copies
registry metadata; MonitorControl uses the same private CoreDisplay location
mapping. The public UUID conversion lives in ColorSync, without a freshness
contract. A synthetic-only fixture confirmed IODisplay dictionary matching can
succeed with serial and location absent; it must not replace strict policy.

Ten additional offline collector failure tests pass. No new passive recording,
disconnect or display-configuration operation ran. Full-suite live-window
geometry failure is retained separately from passing focused observer/recovery
checks; see the linked validation record. Production enable remains blocked.

## Passive observer checkpoint (2026-10-02)

The [bounded read-only observer](recovery-identity-observer.md) completed one
60-second passive control at `001846a`. Initial notification iterators drained
before recording readiness; nine service interests were registered. No subsequent
IOKit/CG callbacks were received. Two inventories and all recovery snapshot/ICC
fields matched; unknown offline ID 4 remained present. Cleanup and private
artifact permissions passed independent checks. No display state changed.

This qualifies the passive recording path only, not event-delivery completeness,
physical monitor lifetime, or logically-offline identity. Physical disconnect
has not been tested or approved. Private re-enable remains blocked.

## Continuation checkpoint (2026-10-02)

Reused `.worktrees/recovery-enable`, branch `recovery-enable`, clean at
`01880c5`; main remains `e12b2b7`. The Git-local `agent-creation.json` matches
this checkout, branch, creation commit, and prior session
`01a0fd62-0feb-7628-91a8-71b3c2f09949`. Its transcript ends in the matching
completed handoff at 18:02:24Z. The same Pi process is now running successor
session `01a0fdc9-2526-7628-91a8-71d1e20bf4fc`, not concurrent prior work.
Both prior delegated runs have terminal exit-code-zero metadata; process
inspection found no subagent or recovery helper. Existing PanelCtl app/blackout
processes were left untouched. The original receipt was not overwritten.
A receipt copy and adoption evidence are retained privately in
`/var/folders/jp/1mwx72h172955139pth4h8800000gn/T/panelctl-identity-lifetime.TuDhtEXMRC/continuation.json`.

Rechecked macOS 27.0.1, build `26A434`, boot session
`9D95EE40-D277-457A-8A81-A2BCBB7F1CF5`. Read-only enumeration again returned
private IDs `5,1,2,3,4`; IDs `5,1,2,3` report online. Dell ID `1` still has UUID
`09084682-3c42-4455-aab8-126a7431125b`, vendor/model/serial
`4268/16857/1094800204`, shim entry ID `4294970171`, product name
`DELL S2721DGF`, and `DisplayAttributes.PortID=32`. Connector:

```text
IOService:/AppleARMPE/arm-io@10F00000/AppleSoCIO/dispext3@4000000/IOMobileFramebufferShim
```

Independent `ioreg -a -l -r -c IOMobileFramebufferShim` enumeration found five
shims. Both Dell's shim and the unidentified offline ID `4`'s shim
(entry `4294970215`, `disp0@88000000`) report `IOServiceState=30`, busy state
zero, `IOMatchedAtBoot=true`, and `external=true`. `ioreg` describes state 30
as registered, matched, active. The offline entry lacks `IOMFBUUID` and
`DisplayAttributes`; CG still returns no UUID and zero vendor/model/serial.
Thus a registered/active external shim is **not sufficient hardware evidence**.
This does not prove that ID 4 was ever a connected monitor.

`NormalModeActive` is true on the four online shims and false on the offline
shim. `NormalModeEnable` is false on **all five**, including the working Dell.
These observations do not establish an offline identity or a documented link
state contract. DCPIndex is 4 on Dell and 0 on the offline shim; neither index
is a CG ID. Four registered DCPAVServiceProxy objects expose external location
and Unit 0 but no direct per-monitor identity in their property dictionaries.
No user client or IOAV/DDC/link-control operation was opened or called.

Independent service paths correlate Dell's `dispext3` shim with a proxy path
under `dcpext3@6E00000/.../dispext3:dcpav-service-epic:0/DCPAVServiceProxy`
(entry `4294977726`). The shim and proxy are on different registry branches;
matching path tokens are controller correlation, not an independently established
physical-sink → offline-CG-ID binding. The proxy's complete property-key list
contains no CG ID, CG UUID, product identity, or EDID. No AppleCLCD2 services
were found. These are observations of this host, not universal driver contracts.

## What lifetime evidence actually establishes

The installed SDK's `IOKitLib.h` documents:

- `IOObjectIsEqualTo`: same kernel object, not same physical monitor.
- `IOServiceGetMatchingServices`: registered service objects.
- `IOServiceGetBusyState`: asynchronous registration/matching/termination work,
  not physical connectivity or current EDID acquisition.
- `IOServiceAddMatchingNotification`: publication/matching/termination of service
  instances; notifications only arm after draining the returned iterator.
- `IOServiceAddInterestNotification`: messages sent by the service. There is no
  generic promise that replacing a monitor behind a persistent framebuffer
  terminates that service or emits a particular identity-invalidating message.

Apple's [IORegistryEntry.cpp at f6217f8](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/iokit/Kernel/IORegistryEntry.cpp)
was inspected using `gh api`: `attachToParent` assigns an entry ID when absent,
`getRegistryEntryID` returns the object's stored ID, and `getProperty` reads its
property table. Properties can change without creating a new object. This is
generic implementation evidence, **not** the source of this host's private
framebuffer/DCP drivers or proof of their disconnect behavior.

A fresh registry property read is a fresh read of driver-published metadata,
not necessarily a fresh hardware read. Multiple APIs repeating the same value
may share its original producer/cache. A retained service handle, stable entry
ID/path, repeated matching product data, EDID hash, or absent termination event
alone cannot prove that the same physical sink remains attached. The shim's
`IOMFBUUID`/`EDID UUID` remains distinct from the CG UUID; do not translate one
into the other by assumption.

## Required rejection rules (not a qualified provider)

Retain the existing strict inventory/context checks. Additional lifetime
observations may reject a candidate; they must not turn unknown into approved.

| Observation | Required disposition |
| --- | --- |
| Same CG ID, different/missing UUID or vendor/model/serial | Reject ID reuse or unknown identity; never search nearby IDs. |
| Duplicate identities, multiple candidate connectors/services, truncated/invalid enumeration, extra unknown ID | Reject ambiguity/incomplete inventory; do not filter the ghost to make it pass. |
| Same path but changed registry entry ID, or lost/terminated/replaced service | Invalidate old binding. A new object is not a continuation token. |
| Same object/path but changed product, EDID, port, ancestry, adapter, or connector | Reject hardware/connection change; persistent objects do not override it. |
| Unchanged cached metadata without independent offline physical-sink/CG-ID evidence | Reject as unqualified, not a successful match. |
| Changed boot, OS build, console user/session, or WindowServer lifetime | Invalidate prior qualification. Existing boot/build/user checks are necessary, not a substitute for tracking a display-server lifetime. |
| Read failure, notification gap, collector restart, or observed race/mismatch | Stop, retain evidence, no retry writes or weaker fallback. |

Current journals have no qualified service-lifetime evidence. A future provider
would need to capture it before disappearance and revalidate through the existing
locked, durable one-shot/watchdog path. Do not backfill journals or add another
writer/lock mechanism. The existing injection-only identity tests check policy
against asserted inventories, not whether real driver metadata is trustworthy.

## Diagnostic and checks

`scripts/inspect-recovery-identity.swift` now additionally records independent,
bounded class inventories (at most 32 entries each), registry paths/entry IDs,
API statuses, service-plane membership, busy state, selected driver properties,
and same-object path relookup. It records public online enumeration and
boot/build before and after collection, plus active/main/built-in/origin fields.
It saves `report.json` in a fresh 0700 `panelctl-identity-inspection-*` OS temp
directory, mode 0600, and still prints JSON to stdout (artifact path to stderr).
No existing evidence or recovery journal is replaced.

`complete` means the **class iterator** exhausted while valid, not that every
property/API succeeded, every physical display was found, or any offline
binding was validated. Per-entry return codes must be inspected. These snapshot
reports did not collect lifetime notifications; same-object relookup is only a within-sample
observation. The collector is non-atomic and cannot rule out changes between
reads, or prove absence of events between separate runs. Failure/partial output
must not be treated as equality or qualification.

Two retained reports matched after sorting enumerations and excluding capture
time; boot/build, all reported CG rows and all selected registry evidence were
unchanged. Dell was active, external, non-main at `(3440,-4)` in both. Direct
assertions checked JSON output equals the saved artifact, 0700/0600 permissions,
all class iterators complete, successful per-entry APIs, all path relookups equal,
CG/shim product/path correlation, and the unidentified offline entry. Reports:

- `/var/folders/jp/1mwx72h172955139pth4h8800000gn/T/panelctl-identity-inspection-C35A3441-5F0A-47D2-BD2F-9CD002C6272E/report.json`
- `/var/folders/jp/1mwx72h172955139pth4h8800000gn/T/panelctl-identity-inspection-BAD65F6B-00A9-4131-A892-E61679DF3136/report.json`

Validation: `swiftc -typecheck scripts/inspect-recovery-identity.swift` passed;
the diagnostic ran successfully twice. Full `swift test`: 177 tests, 175 passed,
2 skipped (explicit live origin trial and optional retained ICC replay), zero
failures. All trial variables and `PANELCTL_ICC_EVIDENCE_DIR` were explicitly
unset. Release `panelctl` build passed. LSP reported unknown, not clean. No new
provider policy or synthetic qualification tests were added: existing rejection,
one-shot/no-replay, and no-write tests were rerun unchanged. This small diagnostic
delta was checked directly; no new subagent review is claimed.

The original receipt and journals remain unchanged. No recovery helper remains
running. The adopted worktree is retained for further explicitly scoped work;
no additional worktree/workspace was created. No display configuration, private
enable/disable, power, firmware, link, or permanent-preference write occurred.

## Exact missing evidence / stop boundary

Not established: (1) whether the same Dell remains physically attached while CG
marks it offline; (2) which hardware-derived sink/connector observation remains
fresh then; (3) how that observation binds uniquely to the offline CG ID without
WindowServer's cached mapping; (4) whether sink replacement/replug/ID reuse
invalidates the binding even when the shim persists; (5) whether relevant events
are complete and ordered around the CG transition and a prospective enable.

An online-only observation cannot answer these transition questions. Physical
unplug cannot establish physically-attached, logically-offline identity and is
not the next qualification step. The targeted source-contract investigation
has now reached its stop boundary; private re-enable is parked, with no trial
requested or executed. Any future experiment needs a separate exact scope, physical
fallback plan, fresh baseline, and explicit approval. Origin correction also
remains separately gated; `(3440,-20)` has not been restored.

The [historical investigation plan](recovery-identity-investigation-plan.md)
retains the completed passive control and the parked, unapproved physical
negative-control proposal.
It is not physical-disconnect approval, and cannot qualify a physically attached
but logically offline Dell or any private enable call.
