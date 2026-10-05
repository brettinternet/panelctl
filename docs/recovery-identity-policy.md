# Retained-ID identity policy (TASK-12)

Offline implementation of the bounded capture/current contract from the
[canonical plan](display-disable-implementation-plan.md). No private setter,
public restoration, DDC operation or topology write was performed. A production
identity match is not permission to write: the rest of eligibility still
refuses when driver inventory is unknown, and TASK-9 separately requires scoped
human approval.

## Contract

The only production identity scope is `arm64`, host model `Mac17,14`, macOS build
`26A434` (the TASK-1 ABI host). The policy requires the journal and current
observations to agree on boot session, OS build, user and host model. For every
retained display it requires complete, nonzero vendor/product/serial values, a
unique UUID/CG ID, nonempty captured `RecoveryDisplay.connector` and IOKit
transport/location, and exact capture/current equality for hardware, connector,
transport and host context. `connector` preserves its existing CoreDisplay
`IODisplayLocation` meaning (and remains nil in public-mirror captures); the
IOKit `transportLocation` is a separate optional field in identity evidence,
never substituted into the persisted public connector. Online entries must
also retain their UUID and any captured framebuffer location. The production
provider enumerates read-only IOKit DisplayPort transport properties and current
CoreGraphics displays; it refuses incomplete or ambiguous transport matches. When one target is absent, it matches the
retained hardware tuple to one current transport, retains the journaled CG ID,
and never substitutes an enumerated ID.

Identical vendor/product peers, duplicate IDs/UUIDs, zero/missing fields,
additional/unretained online IDs, mismatches, changed boot/build/user/host, and
unsupported hardware/build/architecture refuse with a diagnostic. A missing,
unknown or changed value is never inferred from an online index, journal field,
name, HPD alone, or a new timestamp. `syntheticPhysicalFixture` is still
accepted only for fake-writer tests with synthetic capture provenance; it cannot
upgrade a production capture.

`RecoverySnapshot.capture` records host model and capture-time CoreGraphics,
CoreDisplay (when available), and IOKit transport/location observations without
changing connector semantics. `RecoveryProductionProviders.identityInventory`
takes a fresh read-only capture and transport enumeration for each observation.
Private matching compares the persisted CoreDisplay connector and separate
IOKit transport location strictly against their respective current fields. The
policy is exact matching of those captured and current fields; timestamps are
diagnostic and do not create a freshness guarantee. This is the plan's bounded contract, not proof of a
fresh physical-sink-to-CG-ID binding.

## Decision table

| Evidence | Outcome | Action / what it proves |
| --- | --- | --- |
| Changed boot, OS build or user | stale | Keep journal; manual recovery. |
| Changed captured host model | stale | Keep journal; do not transfer numeric IDs between hosts. |
| Missing host model, identity provenance, nonzero vendor/product/serial, connector/location or transport | missingEvidence | Keep journal; do not infer missing fields. |
| Unsupported hardware model, OS build or architecture | unsupported | Keep journal; production path is limited to `Mac17,14`, arm64, build `26A434`. |
| Duplicate IDs/UUIDs, incomplete inventory, duplicate vendor/product peers | ambiguous | Keep journal; do not select one of identical displays. |
| Any current/captured hardware, CoreDisplay connector, IOKit transport/location or online UUID mismatch | stale | Keep journal; do not substitute a changed display or port. |
| Matching capture/current metadata, including IOKit transport location and type | eligible identity match | Authorizes only the bounded retained-ID identity check; all physical/driver/lifecycle gates still apply. |
| Synthetic fixture identity with synthetic provenance | eligible for tests only | Authorizes fake-writer tests, never production identity. |

`RecoveryIdentityPolicy.evaluate` is shared preflight policy. Re-enable also
requires exactly one missing non-main external target, a verified surviving
physical display, non-mirrored topology, supported host/build, native-only
driver evidence, and fresh lifecycle readiness. It persists one-shot attempt
intent before the injected writer and rechecks identity, environment and
lifecycle around transaction staging/commit. A successful commit is not
reconnection: strict public restoration and verification must still pass.
Unknown identity or environment retains the journal and requires manual action.

## Residual risks and remaining gate

CG UUIDs, framebuffer locations, IOKit registry fields and HPD can be cached.
The implementation does not prove physical acquisition freshness, invalidate a
same-port replacement that reuses cached metadata, or detect numeric CG ID reuse
when every compared field is repeated. IOKit location/transport association is a
bounded exact metadata match, not an independent sink-generation proof. These
limitations are documented rather than solved by a TTL or synthetic authority.

The production driver scan recognizes known DisplayLink/virtual-display names,
but an empty name match is not a qualified complete native-only allowlist; the
provider reports `unknown`. As a result every actual production disable
selection currently refuses at the driver gate even when its identity result is
eligible. Initial awake, console and display state are read-only observations;
unknown lid state prevents using a built-in survivor. Every disable, enable and
public-restoration writer boundary synchronously refreshes lifecycle and the
applicable identity/environment checks. Public restoration keeps its strict
public topology/mode checks without inheriting private-only driver/physical
classification requirements.

No test qualifies hardware, driver acceptance, offline hotplug continuity,
input switching, signal loss, or restored usability. TASK-9 remains blocked by
the unknown driver inventory and requires separate fresh scoped human approval.
No tests in the recovery suites invoke a display writer; all writers are fakes.
