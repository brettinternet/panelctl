# Recovery branch integration review

## Execution follow-through (after the original review)

At `29f2bcd`, current full-suite validation is green: 205 tests, 203 passed and
two intentional skips. Warnings-as-errors, all three release-product builds,
and release-version policy checks pass. The unchanged geometry test passed ten
bounded repetitions before the failure-diagnostic/cleanup-only edit. Its original
failure has not been reproduced or explained; it must not be called fixed.
The new diagnostics retain the original exact first-sample assertion.

This removes the *currently failing suite* integration hold, not the historical
geometry uncertainty. Independent follow-up review of the test change and
[scoped binary evidence](recovery-identity-binary.md) **passed with no validated
findings** (run `c8b27dfd-5d4a-4e68-a8a7-d695e19551b6`, source at `29f2bcd`,
documentation through `fbb5c5a`). It independently read the retained test logs
and decisive assembly. Compiler command flags and release builds were
parent-attested; the reviewer executed nothing. Subsequent `d599846` records
successful x86_64 cross-builds and changes documentation only. Source
readiness and green tests qualify only the gated groundwork. The user's actual
monitor-shutoff/reliable-restoration goal remains blocked on the identity
contracts; it is not delivered by this branch.

## Original static recommendation

**Source review supports the gated groundwork; do not describe the branch as
fully validated or private re-enable as available.** No concrete merge-blocking
safety regression was established by parent inspection and independent static
review. The unresolved [geometry failure](blackout-geometry-investigation.md)
remains a validation hold for an unconditional integration recommendation.
No merge, push, PR, new test run, build, observer run, device call, or display
change was performed for this review.

Reviewed source: `recovery-enable` at `6c00173` against `main` at `e12b2b7`.
Main is the merge base; geometry follow-up `8e7002e` changes documentation only.
The source diff spans recovery comparison/journaling/watchdog logic, private
re-enable groundwork, the origin-trial harness, the explicit observer product,
offline tests, and research scripts. No blackout geometry implementation or
geometry-test changes are present relative to main.

## Established source boundaries

| Area | Review result |
| --- | --- |
| Private re-enable | `RecoveryEngine.reenable` is optional and both production callers construct the default engine without it. `RecoveryReenable.inventory` independently throws by default. No CLI override, app-startup hook, or observer-to-provider connection was found. Missing displays still block. |
| ICC comparison | Only bytes 24–35 (creation time) are excluded after bounded format/date/tag checks. When raw hashes differ, both snapshots must carry matching date-independent evidence. Every other byte remains hashed. This is not proof of emitted-color equality. |
| Legacy journals | Added fields are optional; old journals without normalized evidence remain full-hash strict. No migration/backfill is performed. Identity, connector, topology, rotation and color-space checks remain enforced. |
| Injected enable transaction | Durable one-shot intent precedes backend invocation. Missing-target replay is refused. Transaction cleanup distinguishes cancellation from an already consumed commit. This is policy/transport groundwork, not hardware qualification. |
| Observer | Separate explicit executable; no watchdog launch, restore call, or identity-provider injection. Callback IDs are recorded rather than looked up. Recording completion never authorizes recovery. |
| Packaging | Package.swift adds the observer product. The existing release script still packages only panelctl and PanelCtlApp, not a standalone observer binary. Shared core source is not compile-time isolated merely because its normal entry point is separate. |

### Origin-trial handler is compiled into production

`RecoveryOriginTrial` has a test-only creator in the repository, but the helper
handler in `RecoveryWatchdog.swift:219–239` is part of production core source.
It accepts a validated journal payload and a lease-pipe byte; it is not an
`#if DEBUG` or test-target-only implementation. The environment opt-in gates
the XCTest, not the compiled helper branch itself.

The static trace requires an owner-controlled valid journal, matching current
baseline, helper invocation and pipe request; verify-only trial journals are
rejected. No authorization bypass was demonstrated. Do not claim the shipped
binary contains no origin-trial handler or that the XCTest environment variables
are its sole enforcement boundary. No ordinary CLI command creates the payload.

## Evidence and residual risks

Independent reviewer run `93a68bd4-6927-428a-b59e-62645b32d7d8` read the complete
changed-file manifest and source/test paths, comparing changed core files to
main. It reported **no validated findings**. Parent separately checked backend
call sites, the ICC policy, helper dispatch/journal validation, packaging, and
geometry source/history. Review is static; historical test/trial results were
not independently reproduced.

The last documented focused suite passed 65 tests with two intentional skips;
the full suite recorded two bounds assertion failures in one live-window test.
Neither result is a fresh run. CI still invokes the full suite. A runner without
non-main screens can skip the live geometry test and would not settle that
host-specific discrepancy. Do not silently skip/weaken it to obtain green status.

Still unknown: offline sink freshness and unique CG-ID binding, replacement and
context invalidation, private setter/reconnection behavior, notification delivery
completeness, and the geometry failure's cause. Private re-enable stays parked
at the [source-contract boundary](recovery-identity-contract.md).

Integration must preserve the default backend gate, old journals and strict
identity checks, and accurately retain the geometry limitation. No further live
qualification follows automatically from this review. The existing worktree is
retained for the user's integration decision; no cleanup authorization is claimed.
