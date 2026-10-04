# Recovery foundation reconciliation (TASK-2)

## Scope and provenance

This is a selective adoption, not a merge of `recovery-enable`. Inspected source:
`418fa33a4289f3da4787844be209fbb5d2647cbb`, against main `a4cb2d5` using
`git diff main...recovery-enable`. The source worktree was clean at that revision;
its ownership, branch, and files were not changed. No live display write is
part of this task.

The [canonical plan](display-disable-implementation-plan.md) supersedes the old
universal-identity research stop **only for offline development**. Unknown sink
identity still forbids private writes. A refusal is not successful recovery.

| Component / originating commit | Decision |
| --- | --- |
| Existing main `DisplayRecovery`, `RecoveryJournal`, `RecoveryWatchdog` | Extend the existing subsystem; keep public restoration, locks, permissions, archives and verify-only helper behavior. |
| ICC comparison, `2dcacce` | Adopt `RecoveryColorProfile`, its tests, optional date-independent digest and strict comparison/validation changes. Raw hashes remain evidence; v1 journals without the optional digest stay raw-hash strict. |
| Injected re-enable policy and journal intent, `42a3bd0` | Adopt `RecoveryReenable`, fake transaction ordering, tests, optional engine injection and durable `reenableAttempted` checkpoint. Production callers still use the default engine. |
| Live true-only transport, `42a3bd0` | **Defer** the dynamic loader and live begin/set/complete/cancel closures to TASK-4. This baseline's default enable closure throws even with injected identity. No executable private setter binding is adopted. The branch's SkyLight-only CGS lookup is not the canonical CoreGraphics/SLS fallback contract. |
| Origin trial, `948c575`, and historical timed/parent-exit runs `66530c1`, `01880c5` | **Defer** payload, helper pipe handler and live XCTest. No need to extend the production helper protocol for an origin-only trial. |
| Observer and registry failure tests, `f62cd69` through `5731de0` | **Defer** the separate product, inventory/recording/registry API, scripts and observer tests. They are diagnostic evidence, not a qualified offline identity provider. TASK-3 can use the bounded refusal conclusions below without shipping an observer. |
| Blackout geometry diagnostics `29f2bcd`, Mission Control correction `1105790` | **Defer** unrelated blackout source/tests. Historical 90% shrink and Mission Control coverage are separate findings; neither qualifies monitor shutoff. |
| Identity/source/binary/firmware research through `418fa33` | Preserve the decisive evidence and limits below; do not import a blanket development stop or restart open-ended research. |

All adopted source and tests are on this baseline. This note preserves the
relevant historical evidence without requiring the source worktree or temporary
binary artifacts. Original documents can additionally be inspected with
`git show 418fa33:<path>` while the historical commit is retained; that is
provenance, not a build/runtime dependency. No Apple binaries or serial dumps
are added.

## Preserved identity evidence — historical, not rerun

Read from the branch's `docs/recovery-reenable.md`,
`recovery-integration-review.md`, `recovery-identity-contract.md`,
`recovery-identity-binary.md`, and `recovery-firmware-consumers.md`:

- Published callers agree on a configuration pointer, display ID, C bool and
  CGError setter shape, but this did not establish the host ABI. TASK-1 owns
  host ABI evidence; TASK-4 owns the verified dynamic session-only binding.
- Historical public enumeration had four IDs; private enumeration also returned
  an offline entry with no UUID and zero vendor/model/serial. Do not filter an
  unknown entry merely to obtain an apparently complete identity inventory.
- Apple IOKitUser IOAV source files at
  `323ead896d04424f87184d8f6ff0cce811aab106` contained no implementation.
  Wine/RetroArch caller matching establishes neither fresh acquisition nor a
  unique offline-CG association. Third-party GetID declarations disagreed.
- The local build `26A434` IOKit wrapper `IOAVServiceCopyEDID` at `0x184e130d4`
  uses user-client selector `0x1a`; the DCP proxy sends operation 7 over IPC.
  A new IPC response does not prove a new physical EDID acquisition. Creating
  an IOAV wrapper opens a user client, not just a passive registry read.
- `IOMobileFramebufferGetID` at `0x18fefea30` dispatches to `_kern_GetID`
  (`0x18ff04910`), which returns a populated cached 32-bit value at `+0xad8`
  without another kernel request. This contradicts treating every GetID as a
  fresh sink check, but does not prove ID instability or CG-ID equivalence.
  Inspected IOMobileFramebuffer image UUID:
  `B1C5BB2D-DB25-332B-AD82-CF1EC6170E8B`.
- `AppleDisplayManagerMappingGet` reaches resource mapping, not a proven CG
  namespace conversion. QuartzCore (`216F70F6-AEF9-3D60-942B-F64C636DEF69`)
  has distinct `framebufferId` and `displayId` access paths. Its resource matcher
  returns the first matching CA object; that is not a unique enumerated offline
  CG association or a shared sink/context generation contract.
- DCP firmware was available, not inaccessible/encrypted beyond inspection.
  The extracted image UUID was `64863924-B56B-3E32-87FE-038677F52709`.
  BUND data/fixup reconstruction was incomplete. A candidate EDID helper can
  return virtual EDID or dispatch through a vtable; the operation-7 receiver,
  concrete producer, acquisition freshness and replacement invalidation were
  not conclusively joined. No firmware call was made.

Still unknown: fresh current sink identity, independent unique retained/offline
CG association, and replacement/ID-reuse/context invalidation. Cached metadata,
HPD, a retained service object, and matching integers alone do not fill these
holes. TASK-3 must represent insufficient evidence as explicit refusal, never
invent IDs or treat the fake inventory in these tests as a production provider.

## ICC and lifecycle behavior adopted

Historical color investigation (`ccf1b2f`, `2dcacce`) attributed two regenerated
ICC profiles' raw-hash mismatch to creation-time bytes 24–35. The adopted
comparison only ignores those bytes after bounded v2/v4 display-profile,
date, tag-table and zero computed-ID checks. Every other byte remains hashed;
this is not a general semantic-color comparison. Different raw hashes require
matching normalized evidence on **both** snapshots. Legacy/malformed/unsupported
profiles never get guessed or backfilled normalization. Identity, rotation,
color-space, mode, geometry, main/active and mirroring checks remain enforced.
The optional retained-artifact test is historical replay only, skipped unless
`PANELCTL_ICC_EVIDENCE_DIR` supplies its report/profile files.

The injected missing-display path requires exactly one non-main active external
target, no mirrors, strict remaining topology/context, complete unique inventory,
and nonzero hardware/connector identity. It persists one-shot intent before the
fake writer; missing-target replay is refused after a crash/failure checkpoint.
Transaction tests distinguish cancel-before-completion from consumed completion
errors. Verify-only cannot invoke either writer. The public production path still
refuses missing displays; neither CLI nor watchdog installs a private backend.
No new journal/helper subsystem, user override, startup hook, or retry loop exists.

## Separate historical qualification

The branch reported 205 tests (203 passed, two skips), warnings-as-errors and
arm64/x86_64 product builds after its Mission Control correction. These are
**historical branch results, not results for this adoption**. Its original 90%
geometry discrepancy remained unexplained. The `.stationary` Mission Control
fix addressed a separately reproduced coverage defect, not that discrepancy.

The old origin-trial XCTest was opt-in, but its helper handler was compiled into
production core, not gated by the XCTest environment itself. Neither that handler
nor its test/payload is adopted here. Historical timed/parent-exit origin restore
success does not demonstrate private display re-enable or firmware safety.

## Fresh validation

Fresh TASK-2 checks (2026-10-04 UTC):

- `swift test --disable-sandbox --skip BlackoutGeometryTests.testWindowPlacementOnConnectedExternalScreens`:
  176 tests, 175 passed, one optional retained-ICC-artifact skip, zero failures.
  The live-window geometry test was explicitly excluded for offline-only scope;
  this is not an unfiltered full-suite pass. Log: `.build/task2-offline-tests.log`.
- `swift build --product panelctl -Xswiftc -warnings-as-errors` and
  `swift build --product PanelCtlApp -Xswiftc -warnings-as-errors`: passed.
- `scripts/test-release-version.sh` and `git diff --check`: passed.
- LSP: six affected source/test files clean; `DisplayRecovery.swift` report
  timed out (unknown), not counted as clean. Swift compilation/tests passed.

Independent acceptance/safety verification passed all four TASK-2 criteria
(run `dda1dbe9-1d60-4452-b06e-ad972c7378c2`), with no concrete scoped defects.
The verifier separately ran `swift test --disable-sandbox --filter
'Recovery(Reenable|ColorProfile)Tests'` (15 passed, one optional artifact skip)
and `swift test --disable-sandbox --filter DisplayRecoveryTests` (23 passed).
It confirmed production private-write refusal, legacy v1 strictness,
verify-only behavior, durable one-shot ordering, permissions and locks.

No private setter, DDC write, origin trial, restore/guard command, no-write subprocess rehearsal,
Mission Control probe or surveyed application was executed. Crash recovery here
is fake-writer/persisted-journal evidence, not a fresh live helper qualification.

## Handoff

TASK-3 extends the refusal policy; TASK-4 supplies the verified backend after its
ABI dependency; TASK-5 extends the existing journal/helper. The optional one-shot
field here is groundwork, not the complete disable-intent schema or private
crash recovery. TASK-6/7 must supply physical eligibility and consent gates before
production exposure. Live TASK-9/10 work still requires scoped human approval.
The unrelated `recovery-enable` checkout is retained and is not owned by this task.
