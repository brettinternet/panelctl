# Production provider qualification (TASK-11)

## Verdict: blocked; no hardware qualified

Bounded offline assessment on 2026-10-04, baseline `3e9eab3` on `main`.
Fresh `sw_vers` and `uname -m` report macOS 27.0.1 build `26A434`, arm64.
These establish only the running OS/architecture, not a physical monitor or
fresh sink binding. No target was selected, no real journal/helper created, and
no display setter, public restore, DDC operation, topology change, sleep,
crash or hotplug trial was run. Historical DELL S2721DGF/DisplayPort evidence
is not a fresh observation of today's target or survivor.

The existing evidence does not support a production identity provider, online
or absent. In particular, it does not establish acquisition freshness, a unique
physical-sink-to-retained-CG-ID association, and replacement/ID-reuse invalidation
as one contract. Stop that seam here. Repeating cached queries, assigning a TTL,
or adding an architecture detector cannot close it. No new production provider
or authority-bearing binding case is introduced; existing safe refusal remains.

## Bounded evidence matrix

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

## Command-to-writer trace

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

## Exact resume condition

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

## Proposed next investigation — approval pending

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
