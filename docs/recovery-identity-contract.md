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

## Findings — published-source boundary reached

### 1. IOAVServiceCopyEDID: byte provenance stops at the call

Apple IOKitUser at `323ead896d04424f87184d8f6ff0cce811aab106` actually
contains [`audio_video.subproj/IOAVService.c`](https://github.com/apple-oss-distributions/IOKitUser/blob/323ead896d04424f87184d8f6ff0cce811aab106/audio_video.subproj/IOAVService.c)
and [`IOAVService.h`](https://github.com/apple-oss-distributions/IOKitUser/blob/323ead896d04424f87184d8f6ff0cce811aab106/audio_video.subproj/IOAVService.h).
**Both contain only license comments/whitespace.** `IOAVLib.c` and
`IOAVLibPrivate.h` at that revision are likewise empty of implementation.
The recursive Git tree was not truncated. This is a concrete source boundary,
not merely an unsuccessful symbol search; these filenames do not expose the
user-client selector, producer/cache, driver path, or refresh rules.

The caller-side trace is established:

```text
registered DCPAVServiceProxy
  → IOAVServiceCreateWithService
  → IOAVServiceCopyEDID(service, &data)
  → CFData bytes → parsed vendor/product/serial → metadata match
```

The preceding hardware-to-buffer edge is **unknown**. No inspected implementation
establishes whether the bytes come from a new DDC transaction, firmware cache,
driver property, override, or another producer. Neither successful return nor
creating/releasing the IOAV wrapper specifies cache refresh or invalidation.
DDC provenance described in application comments is not a callee contract.

Pinned caller checks:

- [Wine `cocoa_display.m:561–626,898–951`](https://github.com/wine-mirror/wine/blob/455e3509b98a6919fd4ad1def4803e08c41c03b2/dlls/winemac.drv/cocoa_display.m#L561-L626):
  starts from online CG/NSScreen IDs and returns the first EDID matching the CG
  vendor/model/serial tuple. It does not inspect all candidates for duplicate
  identity or produce a driver-to-offline-CG association.
- [RetroArch `dispserv_apple.m:724–882`](https://github.com/libretro/RetroArch/blob/64846baa730429a8cc58938092419aa5a1d57c6c/gfx/display_servers/dispserv_apple.m#L724-L882):
  another caller uses the same proxy/API path; accepts absent serial on either
  side, stops at the first match, and even accepts one responding external
  candidate when identity does not match (873–877). This is presentation logic,
  not recovery authorization. Its DDC description does not expose acquisition
  timing or invalidation inside `CopyEDID`.
- [Fastfetch `brightness_apple.c:10–16,51–119`](https://github.com/fastfetch-cli/fastfetch/blob/5f65515c3cdc89383415cadbe01c313523313616/src/detection/brightness/brightness_apple.c#L10-L16)
  declares `CopyEDID` but does **not** call it; its EDID path calls
  `IOAVServiceReadI2C`. Do not count a declaration/search hit as another
  `CopyEDID` implementation, or import a different I2C operation's semantics.
- [toggle-display `IOAVService.h:27`](https://github.com/nullne/toggle-display/blob/ca3d56e8e4d34ce1b2991e8d152b1760a3e9812d/Sources/CPrivateAPIs/include/IOAVService.h#L27)
  declares a one-argument, `CFDataRef`-returning function, unlike the two-argument,
  `IOReturn` form used by Wine/RetroArch. This establishes disagreement among
  third-party declarations, not which ABI this host implements. No signature
  from this investigation is approved for invocation.

### 2. IOMobileFramebufferGetID: no documented offline-CG join

The exact namespace on this host remains **unknown**. The inspected source
supports neither treating a framebuffer ID as `CGDirectDisplayID` nor treating
`GetDisplay` / `CreateDisplayList` as a documented conversion to that namespace.

- [iofb-utils header:49–80](https://github.com/AAlx0451/iofb-utils/blob/530c84478860cd564b07ea698ae4b7147da6fe84/include/IOMobileFramebuffer/IOMobileFramebuffer.h#L49-L80)
  separately declares `GetTypeID`, `GetDisplay(..., uint32_t display_id)`,
  `GetServiceObject`, `CreateDisplayList`, and `GetID(..., CFTypeRef *id_out)`.
  It supplies no CG namespace, display-list element schema, uniqueness, offline
  membership, or generation contract. In particular `GetTypeID` is not the
  sink/display identity. This is a third-party header, not an Apple guarantee.
- [Clamless `clamless-display.c:27–28,833–924`](https://github.com/TCXM/clamless/blob/d0ff29add46e03d26bf5d760685ec842856cb15e/src/helper/clamless-display.c#L833-L924)
  declares `GetID` with `uint32_t *`, different again from the header above.
  Its explicit warning says framebuffer service ID 2 can differ from built-in
  CG ID 1; this is the author's report, not a reproduced host result.
  Its actual control flow first checks enumerated SkyLight/online CG IDs for
  a built-in display, then uses a saved hint or `GetID`. The fallback returns
  the integer without checking it against a newly enumerated offline CG ID.
  It therefore does not demonstrate a mapping to such an entry; nor does
  built-in selection establish the external physical sink we require.
- Exact `AppleDisplayManagerMappingGet` search returned SDK export and binary-diff
  listings, not a documented signature, mapping schema, or implementation.
  These listings were not analyzed as binaries. A name containing “Mapping”
  cannot supply the missing edge. No source contract for its context lifetime,
  replacement handling, or relation to CG enumeration was located.

The missing trace is:

```text
current physical sink + acquisition generation
  → framebuffer identity in a specified namespace
  → independent, unique mapping in the same lifetime
  → CG ID actually enumerated while offline
```

Numerical equality, metadata equality, an IOService object, or a saved online
CG ID cannot substitute for any arrow. No inspected source specifies an atomic
or generation-checked association across the driver and WindowServer contexts.

### Three-part verdict

“Contradicted” below refers to the inspected candidate's claimed qualification,
not proof that the underlying private API can never support another mechanism.

| Candidate | Fresh current physical sink | Independent unique enumerated offline CG association | Replacement / ID-reuse / context invalidation |
| --- | --- | --- | --- |
| `IOAVServiceCopyEDID` interface itself | **Unknown** — producer and acquisition time not exposed in inspected source | **Unknown** — no specified CG join | **Unknown** — refresh, replacement, reuse and context rules absent |
| Wine / RetroArch EDID matching as the association | **Unknown** — callee provenance unresolved | **Contradicted** — metadata match / first candidate; not an independent offline join | **Unknown** — no cross-subsystem generation contract |
| `IOMobileFramebufferGetID` and related list/service declarations | **Unknown** — identifier is not fresh sink evidence | **Unknown** — namespace and conversion unspecified; third-party mismatch report argues against assuming equality | **Unknown** — sink, ID and context lifetimes unspecified |
| Clamless cached-hint / `GetID` fallback as the association | **Unknown** — no external sink acquisition proof | **Contradicted** — fallback can return an ID absent from the enumerated lists | **Unknown** — hints/retries supply no shared invalidation contract |
| `AppleDisplayManagerMappingGet` | **Unknown** | **Unknown** — export name only | **Unknown** |

No candidate has all three requirements established. Byte-returning caller paths
and the inadequacy of the inspected joins are established; **fresh offline sink
identity is not**. Matching metadata alone does not pass even if its serial is
unique in a particular snapshot.

## Stop decision

**Park private re-enable.** Keep the production backend blocked, strict identity
policy intact, unknown offline ID 4 unfiltered, and old journals unchanged.
There is no next capture or physical-unplug qualification step. The previous
physical negative-control plan is historical, not the continuation of this work.
Local binary analysis would need separately agreed scope; it is not implicitly
authorized by this result and would not itself automatically qualify a backend.
Reopen only for concrete evidence addressing the missing producer, independent
offline join, and invalidation contracts.

No concrete PanelCtl observer failure emerged from this interface trace, so no
source changes, regression tests, generic tests, or diagnostic framework changes
were made. Source inspection confirms `RecoveryReenable.inventory` still throws
by default; no runtime invocation was needed. Geometry failure remains a separate
unresolved investigation; no origin correction or display-changing action ran.

### Search and evidence limits

All GitHub operations used `gh`; pinned contents were fetched as text, never
compiled or executed. Exact-name searches in `apple-oss-distributions` returned
no hits for either target; importantly, the direct IOKitUser tree/file check
above did find the empty IOAV files. Thus index absence is not treated as proof
of source absence. Global searches were bounded to 30 hits per target and 10
for `AppleDisplayManagerMappingGet`; related `CreateDisplayList` search was
bounded to 15. Duplicate forks, export lists and binary-diff listings did not
count as implementations. The result is limited to these inspected publications,
not a claim that all possible private source or documentation was exhausted.

## Checkout and validation scope

Continue documentation on the existing clean `recovery-enable` branch at
`1773797`, in `.worktrees/recovery-enable`; do not create another checkout or
modify the original creation receipt. The receipt matches path/branch/base and
prior continuation is recorded in `recovery-offline-identity.md`. Historical
session inspection is unavailable under this session's access boundary; no
ownership-based cleanup authorization is claimed. Retain the checkout/workspace.

Validation: `git diff --check` passed; all 14 local Markdown links across the
five changed documents resolve. Decisive pinned passages were read directly,
including the complete empty Apple IOAV files and the caller selection paths.
The diff changes documentation only. No runtime tests or LSP checks were run;
neither can establish these missing private contracts. The existing live-window
geometry failure remains separate and unresolved.
