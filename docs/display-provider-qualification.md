# Production provider qualification (TASK-11 / TASK-12)

## Current verdict: private gate blocked; no hardware write-qualified

TASK-11's assessment below records the historical baseline from 2026-10-04
(`3e9eab3`). TASK-12 later implemented the plan's bounded production
capture/current identity and read-only preflight observations; the current
status and fresh no-write rehearsal are recorded at the end. The historical
assessment remains evidence of what was known then, not the current provider
implementation.
Fresh `sw_vers` and `uname -m` report macOS 27.0.1 build `26A434`, arm64.
These establish only the running OS/architecture, not a physical monitor or
fresh sink binding. No target was selected, no real journal/helper created, and
no display setter, public restore, DDC operation, topology change, sleep,
crash or hotplug trial was run. Historical DELL S2721DGF/DisplayPort evidence
is not a fresh observation of today's target or survivor.

The historical evidence did not support a production identity provider under
the earlier fresh-sink-binding contract. TASK-12 adopted the canonical plan's
bounded exact capture/current match instead. That change does not solve physical
acquisition freshness, same-port replacement or retained-ID reuse; the current
residual risks and fail-closed driver status are recorded below.

## TASK-11 historical bounded evidence matrix

“Observed” below does not mean “qualified.” The preserved historical research is
in [reconciliation](recovery-reconciliation.md); the software contracts are in
[identity policy](recovery-identity-policy.md) and
[eligibility/lifecycle](recovery-eligibility.md).

| Required property | Available provenance / independently established fact | Missing evidence and disposition |
| --- | --- | --- |
| Host/OS support | Fresh host commands above match TASK-1's historical ABI tuple; `RecoveryDisplayBinding` limits loading to its qualified architecture/build and image/symbol origins. | ABI shape is not driver acceptance or sink identity. Other OS builds/Intel remain unsupported. No setter executed. |
| Online retained-ID identity | `RecoverySnapshot.capture` reads CG online IDs, UUID/vendor/model/serial and CoreDisplay `IODisplayLocation`, labeled `cgAndCoreDisplay`; console user and boot/build are also checked. | Metadata can be cached. Enumeration plus matching fields does not independently bind a current physical sink to the CG ID. Re-reading and a fresh `capturedAt` do not change provenance. Production remains unsupported. |
| Absent retained-ID identity | Historical private enumeration included an offline entry without UUID and with zero hardware fields. Historical IOMobileFramebuffer GetID returns a cached value; QuartzCore has distinct framebuffer/display ID access paths. | No proven unique offline-CG association or generation contract. Retained ID, equal integers, port location and registry lifetime cannot authorize enable. No substitution or ID sweep. |
| Fresh physical acquisition/invalidation | Historical IOAV CopyEDID selector `0x1a` reaches DCP operation 7; a candidate firmware helper may return virtual EDID. | Fresh IPC is not fresh sink acquisition. Operation-7 receiver, concrete producer, replacement invalidation and CG mapping were not conclusively joined. No new IOAV client or firmware probe; no universal research restart. |
| Target physical classification | Historical IOPort DisplayPort transport/HPD and framebuffer attributes; current software has CG builtin/active flags. | HPD high, external flags and a monitor name do not exclude ghosts/virtual devices or prove the current target. No qualified `physical` observation for the target. |
| Surviving physical screen | Policy requires another physical, online, active, awake screen with a usable mode; CG can report online/active/mode. | Those flags do not prove physical usability. No fresh positively classified survivor, and no user-visible confirmation. Empty/default environment refuses. |
| Driver exclusion | Policy rejects DisplayLink, virtual and unknown driver states. | No qualified complete native-only driver inventory or mutation-boundary invalidation source. Absence of a named process would not prove absence of drivers. Remains unknown. |
| Awake/lid/current console state | Capture checks console membership. Historical survey identifies IOPMrootDomain `AppleClamshellState`; workspace supplies notifications. | Console membership is not system/display-awake proof. No qualified initial system/screen/session/lid observation, nor freshness across synchronous transaction boundaries. Do not infer awake or not-applicable lid from host architecture. |
| Lifecycle/topology changes | Runtime maps workspace and screen-parameter notifications into matching suspensions, a revision and bounded settling. Fake tests establish state-machine behavior. | Queued events are not synchronous fresh state. Initial state remains unknown; wake events alone cannot upgrade it. No qualified low-level topology/driver/physical invalidation coverage. |
| Identity reuse/replacement and unsupported cases | Pure policy compares complete identities, connector and host context, rejects duplicates/zero identity and stale/unqualified bindings. Synthetic tests can assert a binding. | Test assertions are not observation provenance. Same-port replacement, recycled IDs with cached fields, identical monitors, virtual/headless/DisplayLink, missing serials and absent-sink freshness remain unsupported. Never promote `syntheticPhysicalFixture`. |

No independently supportable *complete* observation contract was found for a
production seam. Existing host/context and CG capture diagnostics are retained,
not duplicated or upgraded into authorization. The environment and lifecycle
seams must be qualified separately even if the identity gap is later closed.

## TASK-11 command-to-writer trace (historical)

- `RecoveryCLI.disable`: exact selection/capture agreement → production
  `preflight` → `RecoveryPrivateSession.prepareDisable` → identity/environment/
  lifecycle selection **before** transaction construction and helper arming.
  The default inventory throws; independently, default environment and initially
  unknown awake state also refuse. Consent flags do not change providers.
- Helper disable repeats selection and lease checks. `RecoveryDisable.perform`
  validates snapshot, identity, environment/lifecycle and lease before intent
  persistence and through `RecoveryEnableTransaction.configure` before begin,
  setter and completion. Failed pre-completion checks cancel; completion is
  session-only and consumed even on error.
- Owned enable/panic/startup recovery loads retained journal intent, not current
  selection. `RecoveryEngine` requires staged/commit intent and one-shot budget;
  `RecoveryReenable.target` validates the absent target and remaining topology,
  then fresh inventory. The session checks lifecycle before writer construction
  and the transaction repeats identity/lifecycle validation at its boundaries.
  Public restoration in the private session also checks lifecycle.
- Recovery does not independently refresh `RecoveryEligibilityEnvironment` at
  every enable boundary; notification wiring alone is not a future production
  preflight provider. This remains a qualification blocker, not a reason to
  weaken the default refusal or to claim all future production races are solved.
- Persisted evidence is diagnostic, not provider authority. The only eligible
  binding is synthetic and requires synthetic capture provenance. No real
  capture can qualify with it.

## Verification

Existing fake tests cover stale/unqualified identity, context/ID/connector
replacement, duplicates, unsupported architecture/build, survivor loss, unknown
physical/driver/lid state, selection invalidation, and sleep/wake deferral.
TASK-11 adds isolated refusal tests for the default environment, default initial
lifecycle even after resume events, and production-labeled provenance with fresh
timestamps/HPD attempting to use a synthetic binding. Writers are injected fakes
or failure sentinels; none of these assertions qualify hardware.

Fresh validation on 2026-10-04:

- `swift test --disable-sandbox --filter 'Recovery|DisplayRecovery'`: 81 core
  tests, one optional retained-ICC-artifact skip, zero failures; the filter also
  ran one app recovery test successfully. Log: `.build/task11-recovery-tests.log`.
- `swift build --product panelctl -Xswiftc -warnings-as-errors` and
  `swift build --product PanelCtlApp -Xswiftc -warnings-as-errors`: passed.
  Logs: `.build/task11-cli-build.log`, `.build/task11-app-build.log`.
- `git diff --check`: passed. LSP diagnostics for the changed test timed out
  (unknown, not clean); compiler/test results supply verification.

Independent read-only safety review completed (run
`de8a264b-8a87-498a-9f79-660b665cd174`): no validated findings. It traced
capture provenance, CLI/helper selection, transaction boundaries and recovery
intent/lifecycle gates, and confirmed the new tests isolate their intended
refusals. It retained all five provider gaps below, including recovery-boundary
environment refresh. No qualification is claimed.

## TASK-11 historical exact resume condition

TASK-9 remains blocked. A new scoped decision must either defer private disable
and retain safe refusal, or authorize a bounded evidence-acquisition proposal
naming a specific source that could establish physical acquisition freshness,
unique retained-ID mapping and replacement/context invalidation, including while
absent. A proposal must state allowed observations, stop conditions and any
separately requested hardware action; this assessment grants none. If no such
source is available, do not repeatedly reopen the same research.

Only after that evidence and separate physical/driver/initial-state and
mutation-boundary lifecycle qualification can a reviewed production provider be
implemented. Then TASK-9 still needs fresh exact-target, short-timeout, usable
survivor, presence and fallback consent. Ordinary consent alone cannot make the
current provider safe. TASK-10 still waits on actual input-return observations.

## Decision (2026-10-04)

The investigation below was **not approved** as the TASK-9 path. Even a full
success would close only one gap and could not establish retained-CG-ID
mapping. The freshness/unique-absent-mapping bar applied above also exceeds the
canonical plan, which deliberately defers the full offline identity contract.
Provider work proceeds in TASK-12 under the plan's contract: exact
capture-evidence matching, otherwise refuse. Residual risks are documented
there, not claimed solved. The proposal is kept for possible later
identical-display hardening only.

## TASK-11 proposed next investigation — not approved

The user requested a scoped proposal, not execution or hardware permission.
The single candidate source is the historical DCP firmware operation-7 receiver
and concrete EDID producer on build `26A434`, starting at the unresolved BUND
reconstruction boundary in `418fa33:docs/recovery-firmware-consumers.md`.
This is a candidate for acquisition/invalidation evidence only, not a promised
solution to retained-CG-ID mapping.

Proposed scope:

1. Verify availability and hashes of the existing local firmware artifacts
   against the historical record (image UUID
   `64863924-B56B-3E32-87FE-038677F52709`). A mismatch or missing artifact stops
   this proposal; do not silently substitute another build or obtain firmware.
2. Attempt one bounded static reconstruction of BUND data/fixups. Validate
   segment layout and relocation provenance before treating candidate pointer
   records as dispatch evidence. Do not repeat the failed full disassembly or
   infer a dispatch table from adjacent strings.
3. Only if reconstruction succeeds, trace operation 7 to its concrete producer,
   distinguishing virtual EDID, cached bytes and physical acquisition, then
   identify explicit replacement/disconnection invalidation paths. Report
   exact addresses, artifact hashes, validated edges and unresolved edges.

Allowed after approval: local read-only artifact inspection and static analysis,
with derived scratch reports. Excluded: opening IOAV/device clients, firmware
calls, live probes, topology changes, private setters, public restoration, DDC,
provider implementation, and changes to identity policy. No uploads or new tool
installation without separate permission.

Stop after this one reconstruction/trace pass if layout, receiver, producer or
invalidation cannot be established; publish a negative result rather than branch
into other interfaces or universal research. Even a successful trace does not
attest the running firmware or prove unique online/absent retained-CG mapping.
Those and physical/driver/lifecycle qualification remain separate gates requiring
another decision. Execution of this proposal requires explicit approval.

## TASK-12 historical offline implementation and rehearsal (2026-10-05)

Production capture records `hw.model`, CG identity, optional CoreDisplay
`IODisplayLocation`, and read-only IOKit DisplayPort transport/type/location/HPD.
The persisted connector retains its historical CoreDisplay meaning (including
nil in public-mirror captures); IOKit `transportLocation` is separate optional
identity evidence, not a replacement. Current identity inventory rereads the
snapshot and transport inventory, requiring exact nonzero vendor/product/serial,
CoreDisplay connector, IOKit transport/location and host context. It rejects
identical vendor/product peers, incomplete or duplicate matches, changed
IDs/context and unsupported host/build. Production scope is limited to
`Mac17,14`, arm64, build `26A434`. This is the canonical plan's bounded
capture/current contract, not proof of fresh physical acquisition. Cached IOKit
or CG metadata could conceal a same-port replacement or reused ID.

Eligibility reads online/active/mode state, requires one matching active/high-HPD
external IOKit transport for an external physical classification, and reports
unknown when evidence is incomplete. It recognizes known DisplayLink and
virtual-display services but does **not** infer native-only from a scan with no
known prohibited name; no complete native-only allowlist is qualified, so
production driver state remains `unknown`. Initial lifecycle observation reads
IOPMrootDomain power/clamshell state, current-console user/session and
CoreGraphics screen awake state (inactive mirror destinations can still be awake).
Disable, enable and public restoration
synchronously refresh applicable environment/lifecycle at each writer boundary.
Public recovery keeps its strict topology/configuration policy without private
physical/driver restrictions.

Fresh test-only no-write rehearsal command: `swift test --disable-sandbox --filter 'RecoveryProductionProviderTests'`. Result: passed; no writer was
constructed. Host `Mac17,14`, build `26A434`, arm64; lifecycle awake `true`, lid
`unknown`; identity verdict `eligible`, complete capture/current match;
mirroring `false`. DELL S2721DGF (ID 1, IOKit transport location
`Port-USB-C@3/DisplayPort`, 1440x2560), K272HUL (ID 3,
`Port-USB-C@1/DisplayPort`, 1440x2560), and AW3425DW (ID 2,
`Port-HDMI@1/DisplayPort`, 3440x1440) were observed online, active, High-HPD,
and classified physical with usable modes. Dell AW3423DW (ID 5,
`Port-USB-C@2/DisplayPort`, 3440x1440) was an online, active, High-HPD physical
survivor candidate. Persisted connector fields remained their separate CoreDisplay
`IODisplayLocation` values; id 1 was observed at an `IOService:/.../IOMobileFramebufferShim`
location. No target was selected. Each target verdict was refusal:
`DisplayLink, virtual or unknown driver state`; all three have other observed
survivor candidates. No actual disable target was selected, no journal/helper
was armed, and no display state changed.

This is a valid no-write refusal, not TASK-9 qualification or approval. The
remaining exact gate is a qualified complete native-only driver inventory plus
separate fresh scoped consent. The historical DCP proposal above remains
unapproved and was not executed.

### Final offline validation and safety review

Independent review `8ca963d8-65b8-4c97-a523-ab3467e6d975` found four defects;
a scoped correction pass addressed each with regression tests:

- Public restoration now rejects newly observed asleep screens without private
  driver/physical gates (`testPublicRecoveryBoundaryRefusesFreshAsleepScreenWithoutPrivateGates`).
- Awake inactive mirror destinations permit public unmirror
  (`testAwakeMirrorDestinationPermitsFakePublicUnmirrorRestoration`).
- Legacy connector semantics remain unchanged; IOKit location is separate
  (`testLegacyPublicAndMirrorConnectorsMatchFreshTransportEvidence`).
- Watchdog sleep deferral survives real asleep observations and recovers after
  resume/settling (fake-helper `runtime-sleep` and expiry cases).

Final parent verification: `swift test --disable-sandbox` passed 314 tests
(4 skips), including the no-write rehearsal; both `panelctl` and `PanelCtlApp`
builds passed with `-Xswiftc -warnings-as-errors`; `git diff --check` passed.
Logs: `.build/task12-final-tests.log`, `.build/task12-final-cli-build.log`,
`.build/task12-final-app-build.log`. An earlier full run had transient native-menu
focus assertions; subsequent full runs passed. LSP diagnostics timed out
(unknown, not clean). No second general review or hardware trial was performed.
Driver-inventory qualification remained a TASK-9 blocker at that checkpoint, not an inferred success.

## TASK-23 native-only inventory (2026-10-05)

This supersedes only the TASK-12 driver-inventory blocker. `nativeOnly` now
requires positive read-only evidence, scoped to Mac17,14 / arm64 / build 26A434:

- A complete, valid IOKit service-plane traversal with readable properties and
  names. Known DisplayLink/virtual labels prohibit native-only qualification.
- Exactly five distinct `IOMobileFramebufferShim` services with distinct registry
  IDs, full paths and DCP indices 0...4. Bundle, kernel bundle and personality
  publisher must all equal `com.apple.driver.AppleMobileDispT605X-DCP`.
  Additional/foreign framebuffer services, duplicates or missing slots refuse.
- Every online CG ID maps to exactly one of those services via its CoreDisplay
  `IODisplayLocation`; two CG IDs cannot share a service. The complete online CG
  inventory is counted and enumerated with overflow detection, then rechecked
  after observation along with the captured topology/identity. The five slots
  are hardware services, not five online displays: unused or retained offline
  slots are expected. Cached `DisplayAttributes` are not online-state authority.
- A successful, strictly parsed full `kmutil showloaded --list-only
  --variant-suffix release` inventory containing the framebuffer driver and
  IOKit KPI, with no non-Apple identifiers or duplicate rows. A successful
  `systemextensionsctl list` must report exactly `0 extension(s)`. Any nonempty
  extension inventory (even unrelated/inactive), unknown format, stderr,
  command failure or timeout refuses. Each command has a two-second deadline.

There is no cached native-only verdict. Existing session environment refresh
reruns this inventory synchronously before private writer construction and at
begin/stage/commit boundaries for disable and journal-driven enable. Public
restoration retains its separate strict topology policy and does not gain these
private-driver restrictions. Fake tests cover all inventory refusals before
writer construction, successful fake disable/recovery, and newly arriving
extensions/kexts or lost mappings at writer boundaries.

### Fresh target-host no-write rehearsal

Command: `swift test --disable-sandbox --filter RecoveryProductionProviderTests`.
The fresh observation found **nativeOnly**: four online CG displays uniquely
mapped to five Apple DCP slots, 269 Apple loaded kexts and zero system extensions.
Identity was eligible under the bounded capture/current contract; lifecycle was
awake, lid unknown (all screens external), mirroring false. No writer was
constructed, target selected, journal created, helper armed, or hardware changed.

| Observed display | ID (observation only) | DCP index | Target eligibility | Physical survivor candidates |
| --- | --- | --- | --- | --- |
| DELL S2721DGF, 1440x2560 | 1 | 4 | Eligible, no-write only | 2, 3, 5 |
| K272HUL, 1440x2560 | 3 | 2 | Eligible, no-write only | 1, 2, 5 |
| AW3425DW, 3440x1440 | 2 | 1 | Eligible, no-write only | 1, 3, 5 |
| Dell AW3423DW, 3440x1440 | 5 | 3 | Main display; survivor only | — |

DCP slot 0 was unused. All four displays were online, active, physically
classified and High-HPD. The DisplayPort transport locations were respectively
`Port-USB-C@3/DisplayPort`, `Port-USB-C@1/DisplayPort`,
`Port-HDMI@1/DisplayPort`, and `Port-USB-C@2/DisplayPort`.
IDs, registry paths and this verdict are observations, never reusable authority.

### Limits and next gate

This is positive inventory qualification, **not** proof of private recovery or
signal loss. It trusts the qualified OS's CoreDisplay-to-IOKit mapping and
reported Apple ownership; it is not an independent signature or kernel-integrity
attestation. Observations are not atomic with a later write: synchronous rechecks
and existing lifecycle invalidation bound but do not eliminate topology/driver
races. Cached metadata, same-port replacement and ID reuse remain limitations of
the existing identity contract. Nonzero system-extension inventories and any
changed host/build/framebuffer layout remain deliberately unsupported.

The native-slot/remaining-display contract permits fake absent-target recovery;
actual behavior of those services and paths after private disable is untested.
Any missing or changed inventory must still refuse and preserve the journal.
TASK-9 requires fresh exact-target, timeout, surviving usable screen, user
presence and physical fallback consent. No setter, DDC, restoration, signal-drop,
input-switch, crash, sleep, logout or reboot trial was performed here.

### Offline validation and independent review

`swift test --disable-sandbox` passed 320 tests (four skips). Both `panelctl`
and `PanelCtlApp` built with `-Xswiftc -warnings-as-errors`; `git diff --check`
passed. LSP diagnostics timed out (unknown, not clean). Session logs are
`/tmp/panelctl-task23-full-tests.log`, `/tmp/panelctl-task23-cli-build.log`,
and `/tmp/panelctl-task23-app-build.log`.

Independent safety review `c435e25d-7a13-445e-8bad-030692510e66` reported no
validated defects after tracing the complete diff and private writer/lifecycle
callers. Direct subprocess tests cover launch/nonzero-exit failure; timeout,
stderr, oversized-output and invalid-UTF-8 branches lack direct tests. Fake
boundary tests do not establish actual post-disable registry behavior. No second
general review or live trial was performed.
