# Private re-enable groundwork (not hardware-qualified)

## Boundary

**Parked after the [bounded source-contract investigation](recovery-identity-contract.md).**
Neither targeted interface established the required fresh sink identity,
independent unique offline-CG association, and invalidation. Physical unplug is
not the next qualification step. No observer rerun or binary inspection is
included; the geometry failure remains separate.

There is **no production offline identity provider**, no enable/disable command,
no automatic private recovery, and no startup behavior. The default
`RecoveryEngine` still refuses missing displays. `RecoveryReenable` can only be
injected internally; its default inventory closure also throws. No runtime flag
can override this. Do not wire the private backend to the watchdog until a
provider is qualified independently of stale WindowServer metadata.

Implemented: one true-only `CGSConfigureDisplayEnabled` transaction, strict
identity policy, and an injected recovery path using the existing locks,
write-ahead journal, public restoration, and verification. The transport has no
`enabled` argument exposed to callers: its private C call always passes `true`.
No live enable call, including an already-online no-op, was made.

## Implementation evidence, not just symbols

Sources inspected through GitHub API, pinned here to inspected revisions:

- [displayplacer Header.h](https://github.com/jakehilborn/displayplacer/blob/c23026eb3d73000eb1a14b45d82fd6dd08c921f5/src/Header.h)
  declares `CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef,
  CGDirectDisplayID, bool)`.
  [DisplayPlacer.c](https://github.com/jakehilborn/displayplacer/blob/c23026eb3d73000eb1a14b45d82fd6dd08c921f5/src/DisplayPlacer.c)
  calls it between `CGBeginDisplayConfiguration` and
  `CGCompleteDisplayConfiguration`. It reports setter errors but still commits
  permanently; those policies are intentionally **not** copied.
- [displaytoggle bridge](https://github.com/calvincchan/displaytoggle/blob/9a76bb7c1cb98779ee6c92e1df52b54180e42f39/Sources/displaytoggle/SkyLightBridge.h)
  and [implementation](https://github.com/calvincchan/displaytoggle/blob/9a76bb7c1cb98779ee6c92e1df52b54180e42f39/Sources/displaytoggle/DisplayManager.swift)
  use the same transaction-ref/C-bool signature for `SLSConfigureDisplayEnabled`,
  not a WindowServer connection ID. They use `SLSGetDisplayList` to locate an
  offline built-in display. Also commits permanently; not proof for our external
  Dell or session-scoped private operation.
- [disable-monitor header](https://github.com/janten/disable-monitor/blob/984c65c11a2466692903bf9f5d3afffbbb15644e/DisplayData.h)
  independently declares the CGS setter and
  `CGSGetDisplayList(CGDisplayCount, CGDirectDisplayID *, CGDisplayCount *)`.
- [MacDisplay implementation](https://github.com/jjongkwann/MacDisplay/blob/f408a527615f0161e712adc65fd46295b9b1f3be/core.swift)
  uses those function-pointer signatures and reports offline/ghost entries.
  Its numeric-ID matching and repeated enable attempts are **not** sufficient
  identity/recovery policy for PanelCtl and are not adopted.

The installed Xcode SDK's `CGDisplayConfiguration.h` documents begin/stage/
complete-or-cancel and explicitly says completion consumes the transaction even
on failure. `.forSession` is a login-session setting, not an automatic undo on
parent exit. `.forAppOnly` can revert to the session/permanent configuration,
not necessarily this exact snapshot. The implementation therefore commits only
`.forSession`, cancels pre-completion failures, and never cancels an already
consumed transaction. These are public transaction semantics; the private
setter's actual session-scoped reconnection effect is **unqualified**. Matching
signatures in working source are ABI evidence, not Apple's compatibility promise
or host-level reverse-engineering proof. SLS is investigated but not a silent
fallback. IOAV link/power APIs remain excluded.

## Current-host identity evidence

Read-only `scripts/inspect-recovery-identity.swift` calls `CGSGetDisplayList`
with a bounded buffer and inspects CoreDisplay metadata and IORegistry. It never
sweeps IDs, opens a link-control channel, or invokes a display setter. Its output
contains serials and should be retained privately.

On macOS build 26A434, current boot:

- Public online list: IDs 1, 2, 3, 5. Private list: 5, 1, 2, 3, **4**.
- ID 4 is offline, has no CG UUID, and vendor/model/serial all zero. It has a
  `disp0@88000000/IOMobileFramebufferShim` metadata path. A path and enumerated
  integer alone therefore do **not** prove a real reconnectable target.
- Dell ID 1 has UUID `09084682-3c42-4455-aab8-126a7431125b`,
  vendor/model/serial 4268/16857/1094800204, connector
  `IOService:/AppleARMPE/arm-io@10F00000/AppleSoCIO/dispext3@4000000/IOMobileFramebufferShim`,
  registry entry ID 4294970171, `external=true`, product name DELL S2721DGF,
  and port ID 32 in `DisplayAttributes`.
- The shim's `IOMFBUUID`/`EDID UUID` is
  `10ACD941-0000-0000-0520-0104B53C2278`, **not the CG UUID**. Do not equate
  them. Product attributes correlate while online, not proof after disconnect.
- No AppleCLCD2 service exists. Four DCPAVServiceProxy services exist, without
  sufficient directly exposed per-display identity to authorize private enable.
- Both CGS/SLS setters and SLS list symbols resolve. No setter was called.

Private raw evidence: `/tmp/panelctl-offline-identity-evidence.json`.
The previous full registry inspection is retained at
`/var/folders/jp/1mwx72h172955139pth4h8800000gn/T/pi-bash-c86c687bca61be8b.log`.

Unknown without a separately authorized disconnect investigation: whether the
Dell retains a live, non-stale hardware/connector → CG-ID binding offline;
whether shim/product properties survive or cache stale values; how ID reuse and
connector reattachment invalidate that binding; and whether the private setter
actually reconnects it. No disconnect was manufactured. A future provider needs
independent registry/service lifetime evidence captured before disappearance,
validated offline, and rejected across boot/OS/hardware/connector changes. The
current journal does not capture that evidence. No numeric-ID or cached-metadata
fallback is acceptable. Existing journals do not authorize private enable.

See the [read-only service-lifetime follow-up](recovery-offline-identity.md) for
current evidence, rejection rules, and the exact remaining disconnect boundary.
Registered/active service objects do not establish an offline physical identity.

## Injected lifecycle and tests

The injected backend requires exactly one missing active, non-main external
baseline display, no mirroring, unchanged remaining identities/context, complete
and unique inventory, matching nonzero vendor/model/serial, exact UUID/ID and
nonempty connector, and consistent online membership. Unknown extra entries are
rejected rather than silently filtered; even the current host's ghost entry is
not grounds for weakening that policy.

Before enabling, the engine durably records `restoring` and
`reenableAttempted=true`. A resumed/crashed or failed attempt is never replayed
while the display remains missing. The transaction revalidates before begin,
before the setter, and before commit. After enable, public online capture must
again pass the unchanged identity guards before public mode/origin/mirror
restoration and exact final verification. API success without reconnection is a
failure; failed final persistence retains the attempted baseline. No write retry
loop exists. Verification-only paths cannot call either writer.

`RecoveryReenableTests` covers missing identities, ID reuse, ambiguous/duplicate
UUIDs, hardware/connector/boot/OS/user changes, unknown evidence, already-online
no-op rejection, API absence/errors, identity races, cancellation/commit errors,
write-ahead ordering, unsuccessful verification, journal failures, and restart
from a persisted crash checkpoint. Private-backend crashes are **simulated with
persisted journals**, not live private calls. Existing no-write subprocess tests
exercise actual parent/helper death independently. They do not qualify private
reconnection, firmware safety, or survival of WindowServer failure.
