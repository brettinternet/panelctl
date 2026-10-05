# Private display disable

Goal: drop this Mac's signal to one monitor so a multi-input monitor
auto-selects another computer, then restore the Mac's display safely. Mirroring
and DDC input select don't cover monitors without DDC, because the Mac's signal
stays on.

## Status

| Piece | State |
| --- | --- |
| Setter ABI | Verified offline for macOS `26A434` arm64 ([evidence](display-enable-abi.md)) |
| Transaction backend, journal, helper lease, CLI | Implemented; fake-writer tests plus one supervised cycle |
| Identity, eligibility, driver, lifecycle providers | Pass a no-write rehearsal on `Mac17,14` / arm64 / `26A434`; refuse everywhere else |
| Live disable/enable cycle | One supervised DELL S2721DGF/M3T101 cycle passed on the tuple below; [evidence and limits](display-disable-trial.md) |
| Signal drop, monitor auto-select, input return | HDMI auto-selection observed; DP return required manual input selection; electrical link state unproven |

Blackout remains the safe overlay alternative.

## Mechanism

Every surveyed tool ([survey](display-disable-tool-survey.md)) uses the same
private setter inside a public transaction:

```c
CGDisplayConfigRef config;
CGBeginDisplayConfiguration(&config);
CGSConfigureDisplayEnabled(config, displayID, false);   // true to re-enable
CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
```

- **Binding.** `dlopen` CoreGraphics and `dlsym` `CGSConfigureDisplayEnabled`;
  fall back to SkyLight `SLSConfigureDisplayEnabled`. Both must match the
  recorded image UUIDs and symbol origin, or the feature reports unavailable. No
  strong import, so a changed OS disables the feature instead of breaking launch.
  The library handle lives as long as any transaction using it.
- **Signature.** `@convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> CGError`.
- **Scope.** Session only. App-only scope strands displays after a force quit;
  permanent scope turns a bad session into a bad boot. No scope undoes the
  private flag when the process dies.
- **Transaction.** Revalidate before begin, before staging, before completion.
  Cancel exactly once on any error before completion. Completion consumes the
  transaction even on error; never cancel after it. No retries.
- **Re-enable** passes `true` with the retained display ID. The display need not
  be enumerable; it usually isn't.

## CLI

```sh
panelctl recovery disable --display UUID --consent-disable --timeout 15s
panelctl recovery status
panelctl recovery enable
panelctl recovery panic
```

- Disable: one UUID, ID or `--index`; explicit consent; timeout 1–60 s. No
  `--all`, no indefinite lease, no startup/login/wake disable.
- The CLI stays attached until the lease ends. Exit, SIGINT/SIGTERM or parent
  death closes the lease and the helper re-enables.
- `enable` and `panic` take no selector; they act only on the journal's staged
  target, even when it's offline. `status` reads only the journal.
- Before a new disable, stranded intent in that journal is recovered (or
  refused) and the command exits 1, requiring a fresh selection.
- All accept `--journal <path>`; keep using the same path. Exit 2 on parse
  errors, 1 on refusal or failed recovery, 0 on success.
- `panic` adds no global reset. It reports refusals and leaves
  `CGRestorePermanentDisplayConfiguration()` as a separate, unverified manual
  step.

## Preflight

Every check reruns on fresh observations before intent is saved, before begin,
before staging and before completion. Any change invalidates the selection;
a new selection needs a new explicit command.

### Target and survivor

| Requirement | Refused |
| --- | --- |
| Apple Silicon | Intel |
| Exactly one target: non-main, external, physical | Main, built-in, mirrored, virtual, headless |
| Another active, awake physical screen with a usable mode | Only virtual/headless/DisplayLink survivors; built-in with lid closed or unknown |
| Non-mirrored topology | Any mirror |
| Native-only driver inventory | DisplayLink, virtual, unknown |
| System, console session and screens awake | Unknown or asleep (a wake notification can't upgrade unknown) |

A screen is `physical` only with exactly one matching IOKit DisplayPort
transport reporting active and HPD high. Online count, UUID, `builtin == false`
or HPD alone don't prove it.

### Identity

Supported only on host model `Mac17,14`, arm64, build `26A434`. The journal and
current observations must match exactly:

| Evidence | Outcome |
| --- | --- |
| Changed boot, OS build, user or host model | stale |
| Missing nonzero vendor/product/serial, connector or IOKit transport | missingEvidence |
| Other host model, build or architecture | unsupported |
| Duplicate IDs/UUIDs, identical vendor/product peers, incomplete inventory | ambiguous |
| Any hardware, connector, transport or online UUID mismatch | stale |
| Everything matches | eligible (identity only; other gates still apply) |

For an absent target, the retained hardware tuple must match exactly one
current transport, and the journaled CG ID is kept; an enumerated ID is never
substituted. Synthetic identity works only in fake-writer tests.

**Residual risk:** UUIDs, framebuffer locations, IOKit fields and HPD can be
cached. This contract can't detect a same-port replacement that repeats every
field, or a reused CG ID. It is exact metadata matching, not proof of a fresh
physical sink.

### Driver inventory

`nativeOnly` requires positive evidence, rerun at every writer boundary:

1. A complete IOKit service-plane traversal with no DisplayLink or virtual
   display labels.
2. Exactly five `IOMobileFramebufferShim` services, DCP indices 0–4, all owned
   by `com.apple.driver.AppleMobileDispT605X-DCP`.
3. Every online CG ID maps to exactly one of those services via its
   `IODisplayLocation`, rechecked after observation.
4. `kmutil showloaded --list-only --variant-suffix release` parses cleanly with
   only Apple identifiers, and `systemextensionsctl list` reports exactly
   `0 extension(s)`. Each command has a 2 s deadline; any error refuses.

This trusts the OS's CoreDisplay-to-IOKit mapping and Apple ownership labels;
it isn't a signature or kernel-integrity check.

### Lifecycle

Sleep, wake, session and screen-parameter notifications suspend writes until
the matching resume, then a 1 s settle. Each transition has a fixed 5 s budget;
exhaustion leaves the journal in `needsAttention` rather than forcing a write.
Notifications are serialized on the helper run loop, but state is also sampled
synchronously at every writer boundary because queued notifications aren't
enough.

## Journal and lease

The helper ([recovery](display-recovery.md#helper)) holds the operation and
journal locks for the whole lease and is the only writer. The parent sends one
`DISABLE <journal UUID> <retained ID>` line over the lease pipe; delivery is not
acknowledgment.

```text
disabling ─ setter OK ─→ staged ─ final validation ─→ commitStarted ─ complete ─→ disabled
    │                       │                             │
    └─ any failure: cancel ─┘                             └─ crash here: recoverable (staged + commitStarted)
```

| Journal field | Meaning |
| --- | --- |
| `disabledByUsID`, `disableAttempted`, state `disabling` | Intent saved before any transaction call; alone never authorizes recovery |
| `disableStaged` | Setter staged; alone never authorizes recovery |
| `disableCommitStarted` | Final validation passed, saved just before completion. With `disableStaged`, authorizes one recovery attempt |
| `disabled` | Completion returned and was saved; not proof of signal loss |
| `reenableAttempted`, state `restoring` | Saved before the single private enable attempt |
| `privateRecoveryClosed` | Write authority retired; later attempts are verify-only |
| `needsAttention` | Refused or failed; evidence kept |

Recovery (deadline, EOF, signal, `enable`, `panic`, startup) all use one engine:

```text
lock → reload journal → identity checks → one private enable
     → ≤6 reads @200 ms → at most one public restore → ≤6 reads → verified | needsAttention
```

- An interrupted enable is never replayed.
- Seeing the retained ID online closes private authority first, then verifies.
  So PanelCtl accepts macOS re-enabling a display (for example after wake) and
  never disables again or rewrites layout to fight it. A recycled ID still fails
  verification.
- Losing the survivor requests recovery; it never relaxes identity.
- Version-1 journals and staging-only journals never authorize private writes.
- Journal saves and display completion aren't atomic. A crash while saving
  `disableCommitStarted` is an uncertain boundary, not proof of a disable.

## Manual failure ladder

1. `recovery status --journal <path>`, then `recovery enable`.
2. `recovery panic --journal <path>` (same checks; can't bypass a refusal or
   replay an attempted enable).
3. Separately approved: `CGRestorePermanentDisplayConfiguration()`, logout,
   reboot. Their effect on the private flag is unverified.
4. Physical replug or a different port. Same-port replug may stay disabled; a
   display on a new port may get a new ID and is not adopted as the old target.

Never escalate automatically. Signal removal, monitor standby and input
switching are separate outcomes, and window placement, Spaces, HDR and color
aren't restored.

## Test coverage

Mutation tests in `Tests/PanelCtlCoreTests/` use injected writers; none call
Apple's setter. A read-only real-loader test checks the verified versioned image
paths and UUIDs without constructing a transaction.

| Risk | Covered by |
| --- | --- |
| Symbol and ABI | `RecoveryDisplayBindingTests`: framework/symbol fallback, image UUID/origin rejection, Intel/unknown OS rejection before loading, handle lifetime |
| Transaction lifetime | Failure before begin, at begin, at setter, before and at completion; cancel only unconsumed transactions; session scope only |
| Disable persistence | `RecoveryLeaseTests`: save failures at each step cancel and revoke authority |
| Process crashes | Subprocess helper killed before/after READY, at begin/setter, before/after completion |
| Re-enable persistence | `RecoveryReenableTests`: one-shot budget across crashes; consumed completion error never cancels or replays |
| Identity | Recycled ID, replaced sink, duplicates, missing fields, changed boot/build/user, extra/missing displays |
| Eligibility | `RecoveryEligibilityTests`: invalidation at every boundary; virtual/headless/DisplayLink, main/built-in/mirrored, survivor loss, closed lid, Intel, sleep budget |
| Driver inventory | Every inventory refusal before writer construction; new kexts/extensions or lost mappings at writer boundaries |
| CLI | `RecoveryCLITests`: parsing, command-to-helper-to-writer flow, exits, journal-only enable/panic, startup recovery |
| Races | EOF, signals, deadline, topology collapse, system re-enable during recovery |
| Concurrency | Operation lock plus journal lock across custom journals |

No-write rehearsal on the real host:

```sh
swift test --disable-sandbox --filter RecoveryProductionProviderTests
```

Result on 2026-10-05 (`Mac17,14`, `26A434`): `nativeOnly`, identity eligible,
awake, lid unknown, no mirroring. No writer was constructed.

| Display | DCP index | Transport | Verdict |
| --- | --- | --- | --- |
| DELL S2721DGF 1440×2560 | 4 | `Port-USB-C@3/DisplayPort` | Eligible target (no-write) |
| K272HUL 1440×2560 | 2 | `Port-USB-C@1/DisplayPort` | Eligible target (no-write) |
| AW3425DW 3440×1440 | 1 | `Port-HDMI@1/DisplayPort` | Eligible target (no-write) |
| Dell AW3423DW 3440×1440 | 3 | `Port-USB-C@2/DisplayPort` | Main; survivor only |

## Trial protocol

Each step needs explicit approval from a person who is present. Green tests,
consent flags and passing preflight are not approval.

Before any write, record: commit and host/OS build; fresh target UUID,
vendor/model/serial, connector and the inputs in use; preflight results; the
user-confirmed usable survivor; exact consent (target, timeout in seconds, one
cycle); journal path and helper READY; no concurrent topology tools; accepted
manual fallback. Never reuse historical IDs.

| Stage | Observe |
| --- | --- |
| Disable | Result, public enumeration, signal loss vs standby vs no-signal message, HDMI auto-select, HPD |
| Retained-ID enable | Driver acceptance, signal and visible output, whether the monitor returns to DP or stays on HDMI |
| Verify | Journal state, topology and exact modes, user-confirmed usable output |
| Verdict | Qualified for that host/OS/monitor/firmware/connection only, or failed/blocked with the exact reason |

Stop on the first unexplained mismatch; don't toggle again. Global restore,
logout, reboot, hotplug, crash and sleep trials each need separate approval
after a successful simple cycle. A refusal is a blocked result, never a
successful cycle.

## Observed result and open questions

- One [supervised cycle](display-disable-trial.md) on Mac17,14 / `26A434` with
  DELL S2721DGF / M3T101 accepted retained-ID re-enable and restored exact
  topology/modes. Other tuples and repeated reliability remain unqualified.
- In that cycle the monitor auto-selected HDMI; standby/no-signal indications
  were uncertain. HPD and link-rate metadata stayed unchanged, so electrical
  link shutdown is not proven.
- DP did not return automatically: manual OSD selection restored usable Mac
  output. Automatic return focus needs a separately scoped solution.
- Does DDC still reach a disabled display, so an input-select follow-up works?
- Does the session-scoped flag survive logout or reboot, and does
  `CGRestorePermanentDisplayConfiguration()` alone re-enable it?

## Out of scope

DDC power, link stop/start, permanent scope, blind ID sweeps, automatic
re-disconnect, gamma blackouts, and automatic logout/reboot. Full offline
identity (fresh sink binding, identical monitors) is later hardening; the
[feasibility research](feasibility.md#offline-identity-research) records why it
isn't solved.
