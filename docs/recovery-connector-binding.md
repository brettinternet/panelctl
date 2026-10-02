# Connector-to-CG-ID binding: source and offline follow-up

## Result

**No qualifying independent, fresh offline binding was found in the inspected
contracts and implementations.** This is a bounded negative finding, not proof
that no private driver mechanism could exist. Production private re-enable
remains blocked. No ID sweep, identity fallback, device user client, IOAV/DDC
transaction, display configuration call, disconnect or new observer run occurred.

The required evidence is still a fresh physical-sink identity, a unique binding
to an actually enumerated CG ID while logically offline, and invalidation on
sink replacement/ID reuse/context change. Knowing a port path or a unique serial
is insufficient if the association or metadata can be cached.

## What the sources establish

| Candidate | Actual evidence | Why it does not qualify |
| --- | --- | --- |
| CG vendor/model/serial and online enumeration | Installed SDK documents monitor metadata and online membership. | No acquisition timestamp, hardware transaction, or offline freshness guarantee. Existing ghost ID 4 has no UUID and zero product fields. |
| `CGDisplayCreateUUIDFromDisplayID` | Public declaration in **ColorSync/ColorSyncDevice.h**, described as converting display ID to UUID; reverse conversion is also declared. | A conversion API is not an independently acquired physical credential. Do not mistake its absence from CoreGraphics headers for a private API, or equate it with IOMFBUUID/EDID UUID. |
| `CGDisplayIOServicePort` | Installed `CGDisplayConfiguration.h:370–373` marks it deprecated, **“No longer supported.”** | Cannot provide a current supported service-binding contract, much less fresh offline sink identity. It was not called. |
| `IODisplayCreateInfoDictionary` | SDK describes hardware associated with a framebuffer. Published implementation finds an IODisplay descendant and copies registry properties. | This is another view of registry-published metadata, not a new hardware read or a CG-ID binding. |
| `kIODisplayMatchingInfo` / `IODisplayMatchDictionaries` | Requests fewer identity keys; matcher compares dictionaries, permitting absent serial/location. Confirmed with a synthetic fixture below. | Matching success does not require complete identity, freshness or presence. Never substitute this heuristic for strict recovery policy. |
| Registry EDID / `IODisplayEDIDOriginal` | Published IODisplay startup uses an existing EDID property when present; hardware acquisition is a separate method. The user-space dictionary adds the registry EDID as “Original.” | “Original” does not mean freshly acquired. A fresh property read cannot prove when the driver acquired those bytes. |
| CoreDisplay location → shim / product attributes | Current diagnostic and MonitorControl both use private `CoreDisplay_DisplayCreateInfoDictionary` and `IODisplayLocation`. | Repeating the same mapping through another application does not create independent provenance. Scored name/serial/EDID matching is weaker, not a solution. |
| Shim/proxy path, PortID, registry entry ID, same-object handle | Existing retained control shows persistent, correlated registered objects; proxy has no direct sink/CG identity. | Controller/object identity is not sink lifetime. No inspected contract promises invalidation on replacement or freshness while logically offline. |
| CG and IOKit notifications | SDK guarantees types of configuration/service notifications and iterator arming. Removed CG IDs can fail lookup even in their removal callback. | No generic cross-subsystem causal order, physical-sink binding, or guaranteed metadata reacquisition. Continue recording callback IDs without looking them up. |
| ColorSync device/profile registration | `ColorSyncDeviceCopyDeviceInfo` describes registered devices resolved for host/user; registration/profile APIs and notifications are separate. | Registration/profile metadata is not a hardware challenge or proof of an attached sink. No registration/profile setter was called. |

### Pinned implementation evidence

GitHub content was retrieved with `gh api`, pinned to these commits, not run:

1. Apple IOKitUser `323ead896d04424f87184d8f6ff0cce811aab106`,
   [IODisplayLib.c](https://github.com/apple-oss-distributions/IOKitUser/blob/323ead896d04424f87184d8f6ff0cce811aab106/graphics.subproj/IODisplayLib.c):
   - Lines 740–773: `IODisplayForFramebuffer` accepts an IODisplay or searches
     descendants in the IOService plane; not a physical connector query.
   - Lines 892–947: copies registry properties and derives vendor/product/serial
     from the stored EDID. No fresh hardware acquisition in this path.
   - Lines 965–1007: output can include overrides; location is a registry path;
     matching-only mode stops before EDID output; `IODisplayEDIDOriginal` comes
     from that same registry data. No freshness token is introduced.
   - Lines 1385–1426: matching requires vendor/product equality but compares
     serial and location only **when both dictionaries contain them**.
2. Apple IOGraphics `76285384ff0ce63965a21b8023bf6d7e447fcc19`,
   [IODisplay.cpp](https://github.com/apple-oss-distributions/IOGraphics/blob/76285384ff0ce63965a21b8023bf6d7e447fcc19/IOGraphicsFamily/IODisplay.cpp):
   - Lines 569–574: startup invokes `readFramebufferEDID()` only if the EDID
     property is absent. Lines 844–912 show separate DDC acquisition and
     publication into `kIODisplayEDIDKey`.
   - This demonstrates separate acquisition versus property copying in the
     published stack. **It is not the source of this host's private M5
     framebuffer/DCP drivers**, nor evidence of how long they cache metadata.
   - [IOFramebuffer.cpp:13512–13549](https://github.com/apple-oss-distributions/IOGraphics/blob/76285384ff0ce63965a21b8023bf6d7e447fcc19/IOGraphicsFamily/IOFramebuffer.cpp#L13512-L13549)
     shows lower-level DDC work, including bus stop sequences and retries. A
     routine described as a read is not automatically equivalent to passive
     registry inspection. No such routine was invoked or added to the observer.
3. MonitorControl `84ac2d72bfb53b653536e484946f6ed027e4229c`,
   [Arm64DDC.swift:128–163](https://github.com/MonitorControl/MonitorControl/blob/84ac2d72bfb53b653536e484946f6ed027e4229c/MonitorControl/Support/Arm64DDC.swift#L128-L163):
   matching consults the same private CoreDisplay dictionary, adds ten points
   for the same location, and fewer points for EDID-derived fields/name/serial.
   Useful application correlation, not independently sourced offline identity.
   None of its DDC/service operations were run or copied into production.

SDK source inspected under
`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/`:
`CoreGraphics.framework/Headers/CGDisplayConfiguration.h` (187–245, 346–373),
`IOKit.framework/Headers/graphics/IOGraphicsLib.h` (49–96),
`ColorSync.framework/Headers/ColorSyncDevice.h` (device/profile registration,
copy-info and UUID conversion declarations). Parent rechecked the decisive
headers and implementation passages after a read-only SDK scout (`ee7cf3fd`).

Web searches also found Apple developer-forum discussions, but direct retrieval
returned incomplete content; their search summaries are **not evidence for this
decision**. A third-party layout-manager note describes the same CoreDisplay
mapping on different monitors; it is not Dell/M5 offline qualification.

## Offline matching fixture

On the current host, `IODisplayMatchDictionaries` was called only with synthetic
CFDictionaries—no display ID, registry handle or hardware query:

| Second dictionary versus full synthetic identity | Returned score |
| --- | ---: |
| Same vendor/product/serial/location | 1000 |
| Same vendor/product, serial and location absent | 1000 |
| Different serial when present in both | 0 |
| Different location when present in both | 0 |

This reproduces the published optional-field behavior and rules out using the
matcher's success as complete identity proof. The initial fixture compile needed
`import IOKit.graphics` rather than the top-level module; after correction all
four assertions passed. It did not observe or mutate any real display.

Private source copies and synthetic fixture:
`/var/folders/jp/1mwx72h172955139pth4h8800000gn/T/panelctl-connector-research.CO7JQhcxaY/`
(directory 0700, files 0600).

## Observer failure tests and validation

Commit `d5a8323` adds ten fully offline collector tests using fake registry
operations/handles, beyond the prior 13 recorder/queue tests. They exercise
registration errors, null/invalid iterators, drain bounds, partial-start cleanup,
interest/retain failures, borrowed callback handles, property/output failures,
service retention bounds and initial-versus-subsequent events. No live registry
registration is needed for these tests. A recording failure now stops a drain
before further interest registration. See [observer details](recovery-identity-observer.md).

- 23 observer tests pass. Focused recovery/identity/ICC suite: 62 tests, 60
  passed, two intentional skips (live origin trial, optional retained ICC replay),
  zero failures. Approval/replay variables explicitly unset.
- Release `panelctl` and observer builds pass; LSP remains unknown.
- **Full suite is not green:** 200 tests ran, two assertion failures in the one
  existing `BlackoutGeometryTests/testWindowPlacementOnConnectedExternalScreens`
  test; both compared compositor-reported bounds after ordering test windows.
  `(172,1512,3096,1296)` differed from `(0,1440,3440,1440)` and
  `(-1368,128,1296,2304)` differed from `(-1440,0,1440,2560)`. Both sizes are 90%
  of expected; cause is not established. No claimed connection to observer code.
  This test creates temporary windows; it was not rerun or changed. Future
  validation for this offline slice should use the focused command, not that
  live-window test. No display configuration writer or recovery trial ran.
- Logs: `/tmp/panelctl-observer-failure-followup-tests.log`,
  `/tmp/panelctl-connector-followup-focused-tests.log`, and
  `/tmp/panelctl-connector-followup-full-tests.log` (0600).

## What would change the decision

A useful next input is a documented or independently verified driver interface
that exposes both fresh acquisition/presence provenance and a unique offline
CG-ID association, with explicit invalidation semantics. A new name for the same
CoreDisplay/registry data, another online snapshot, or an unqualified EDID hash
would not advance that requirement. No such interface was established here.

A separately approved physical unplug could disprove a metadata-presence claim,
but cannot establish the required physically-attached/logically-offline binding.
No unplug, software disconnect or reconnection experiment follows from this
research. Keep unknown ID 4, strict identity checks, old journals and the blocked
production backend unchanged.
