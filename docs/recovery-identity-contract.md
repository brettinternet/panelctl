# Private re-enable identity contract — bounded source investigation

## Scope and acceptance gate

Follow-up to [connector binding](recovery-connector-binding.md). Work is limited
to published source and declarations for `IOAVServiceCopyEDID`,
`IOMobileFramebufferGetID`, and directly related display mapping. No local binary
inspection, device calls, observer rerun, display-changing experiment, origin
correction, or geometry-test investigation is included.

A candidate passes only when **all three** requirements are established:

1. Fresh identity of the currently attached physical sink, including byte
   provenance and refresh behavior while physically attached but logically offline.
2. An independent, unique association with a CG ID actually returned by offline
   enumeration. Matching metadata, equal integers, or cached hints do not pass.
3. Invalidation on sink replacement, ID reuse, and context changes across that
   association; object lifetime alone does not pass.

Record each requirement as **established**, **contradicted**, or **unknown**.
Unknown is a blocking result, not evidence that the interface is necessarily
cached or incapable. A caller implementation cannot establish an undocumented
callee guarantee.

## Bounded plan

1. Search Apple-published source for the two exact interfaces. Trace any located
   implementation to the byte producer / ID namespace and refresh/invalidation
   rules. Otherwise record the implementation boundary explicitly.
2. Inspect a bounded selection of published callers and declarations, pinned to
   revisions: Wine's DCP EDID caller, one additional independent EDID caller,
   framebuffer declarations, and a macOS mapping consumer. Search the directly
   related `AppleDisplayManagerMappingGet` symbol for a documented join.
   Export lists and binary-diff listings are discovery only, not contracts.
3. Score the candidates against the three requirements and document the exact
   missing edges. Add observer regression tests only if this trace reveals a
   concrete observer defect; do not expand diagnostics or add generic tests.
4. If the contracts remain missing, park private re-enable. Physical unplug is
   **not** the next qualification step: absence cannot establish identity of a
   physically attached, logically offline sink. Reopening needs concrete contract
   evidence or separately agreed static binary-analysis scope, not another capture.

## Checkout and validation scope

Continue documentation on the existing clean `recovery-enable` branch at
`1773797`, in `.worktrees/recovery-enable`; do not create another checkout or
modify the original creation receipt. The receipt matches path/branch/base and
prior continuation is recorded in `recovery-offline-identity.md`. Historical
session inspection is unavailable under this session's access boundary; no
ownership-based cleanup authorization is claimed. Retain the checkout/workspace.

Documentation-only changes receive diff/link/evidence checks. No runtime test
suite is appropriate for proving these private contracts. The existing
live-window geometry failure remains separate and unresolved.
