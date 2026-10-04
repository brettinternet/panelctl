# Offline display transaction backend

TASK-4 adds an internal binding, not a CLI feature or hardware qualification.
`RecoveryEngine` and `RecoveryReenable` still default to refusing private writes.
No application startup path resolves or installs the new binding.

`RecoveryDisplayBinding.resolve()` reads the current OS build and checks the
compiled architecture. Only arm64 / build `26A434` is covered by the
[TASK-1 ABI evidence](display-enable-abi.md). Resolution tries CoreGraphics's
`CGSConfigureDisplayEnabled`, then SkyLight's `SLSConfigureDisplayEnabled` if the
framework or symbol is absent. The loaded framework UUID and the setter's
SkyLight origin/UUID must match that evidence. A present but unqualified image
refuses immediately; it does not fall back around an ABI mismatch. New builds
require new bounded evidence, not an expanded allowlist by assumption.

The binding retains its `dlopen` handle until all transactions using its setter
have been released. It uses the verified C convention, opaque configuration
pointer, 32-bit display ID/error and canonical Boolean. No private symbol is
strongly imported. Resolution alone does not call the setter or begin a display
configuration transaction.

The existing `RecoveryEnableTransaction` now stages either Boolean value. Its
`enable` adapter stays true-only for the recovery pipeline. Each operation:

1. Revalidates, then begins a fresh transaction.
2. Revalidates immediately before staging the retained ID/value.
3. Revalidates before completing with session scope only. Disable then synchronizes
   completion-attempt intent before invoking completion (TASK-8); a final-validation
   failure never grants private recovery authority.
4. Cancels exactly once for errors after begin but before complete. Complete
   consumes the configuration on success or failure; neither case cancels it.

There is no scope argument on the operation, no exposed reusable configuration,
and no retry. The journal's existing one-shot intent and post-write verification
remain necessary: completion success does not prove restoration. Completion
failure leaves recovery evidence and cannot be replayed by the recovery engine.

## Validation and remaining gates

`RecoveryDisplayBindingTests` uses injected loaders and a C-convention fake
setter, replacing all public transaction calls before execution. It covers
preferred/fallback resolution, missing libraries/symbols, unsupported platforms,
unknown image identity/origin, handle lifetime, exact-width IDs, both Boolean
values, session scope, all validation boundaries and transaction failures.
`RecoveryReenableTests` covers durable evidence and no replay after completion
failure, plus the existing identity/refusal matrix. Routine tests never resolve
or invoke the live private setter.

Fresh TASK-4 validation (2026-10-04 UTC): `swift test --disable-sandbox`
passed 188 tests with one opt-in test skipped and zero failures (134 core,
54 app). Both `swift build --product panelctl` and
`swift build --product PanelCtlApp` passed, as did
`scripts/test-release-version.sh` and `git diff --check`. `xcrun nm -u` on
both debug executables showed neither private setter as an undefined import.
LSP diagnostics were clean for the binding, shared recovery source and both
affected test files; the transaction source report was unknown (bounded timeout),
so the successful compiler and executable tests are the validation authority.

No actual disable/enable, DDC write, restoration trial, signal-loss observation,
or monitor-input switching has been performed. The production identity provider
remains unqualified. TASK-5 must integrate crash-safe disable intent and watchdog
recovery; eligibility and consent/lifecycle integration remain later gates.
The low-level revalidation closure is an internal orchestration contract, not a
replacement for those guards. No production caller may install this capability
until those gates and the separately scoped human approval are satisfied.
