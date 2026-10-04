# Retained-ID identity policy (TASK-3)

Offline implementation only. No real identity provider is qualified. Production
capture labels CG vendor/model/serial/UUID and CoreDisplay IODisplayLocation as
`cgAndCoreDisplay`, with observation time and boot/OS/user context. These fields
can be cached. Transport and HPD remain absent (unknown), not invented from a
framebuffer integer. The connector location is supplementary metadata, not a
fresh physical-sink binding. No additional live probing or setter was performed.

Journal version 2 retains this provenance beside each display and an optional
`disabledByUsID`. Normal public captures do not set that intent. TASK-5/7 must
persist it before any approved disable. Version 1 remains readable for strict
public restoration but cannot authorize private recovery, even if extra fields
were inserted. Older binaries reject version 2 rather than ignore its intent.
Persisted evidence is never deserialized into provider authority.

## Decision table

| Evidence | Outcome | Action / what it proves |
| --- | --- | --- |
| Changed boot, OS build or user | stale | Keep journal; manual recovery. Numeric IDs cannot cross contexts. |
| Missing capture provenance, zero hardware fields/serial or absent connector | missingEvidence | Keep journal; obtain qualified evidence, never infer it from enumeration. |
| Duplicate IDs/UUIDs, incomplete inventory, duplicate vendor/model/serial | ambiguous | Keep journal; do not select one of identical devices. |
| ID reuse, replacement at same port, different port, changed UUID/hardware | stale | Keep journal; no substitution with a new ID or current selection. |
| Matching cached fields, HPD high, registry-object lifetime or equal framebuffer/CG numbers | unsupported | None proves a fresh sink-to-retained-ID binding. Ghost/virtual entries have no qualified physical binding. |
| Provider reports stale observations | stale | New observation alone is insufficient without qualified binding. |
| Synthetic physical fixture with matching unique, nonzero identities, connectors and host context, and synthetic capture provenance | eligible | Authorizes **fake-writer tests only**; the injected provider asserts a fresh physical binding for this fixture. No real capture can qualify with this binding. |

`RecoveryIdentityPolicy.evaluate` is shared preflight policy. Re-enable also
requires exactly one missing non-main, active external target, no mirrors, strict
public identity/configuration guards for remaining displays, and provider online
IDs matching current enumeration. The engine requires version-2 disabled-by-us
intent for that exact retained ID. It persists one-shot attempt intent before the
injected writer and rechecks identities around transaction staging/commit. A
successful commit is not reconnection: strict public restoration and verification
must still pass. Unknown identity leaves `needsAttention`; no sweep, override or
retry of a consumed attempt exists.

Observation timestamps are diagnostic, not freshness authorization. Synthetic
fixtures model explicit fresh/stale binding states; there is no wall-clock TTL
that turns real cached fields into fresh evidence. No claim is made about driver
acceptance, hotplug continuity, signal loss, input switching or recovery on real
hardware. A future real provider must independently establish physical sink ↔
retained CG ID and freshness before the live gate can open, in addition to the
separate scoped human approval. TASK-4 can continue offline backend work now.

Validation: `swift test --disable-sandbox` exercises evidence/intent round trips,
legacy refusal, eligible absent target, identity/port/context changes, duplicate
and zero serials, unqualified and stale evidence, zero-write refusals, durable
one-shot attempts, public restoration and transaction races. All writers in these
recovery tests are injected fakes.
