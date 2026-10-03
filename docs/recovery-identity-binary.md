# Offline identity — scoped local binary trace

## Outcome

**Actual selected-monitor shutoff and reliable restoration remain blocked, not
completed.** The authorized static trace establishes transport and caching
behavior beyond the published-source boundary, but does not establish the three
required identity contracts. No private interface, user client, DDC transaction,
power command, link command, disable or re-enable operation was invoked.
Production private re-enable remains blocked. No shutoff trial is proposed on
the strength of these findings alone.

The target was the two unresolved interfaces and directly related mapping:
`IOAVServiceCopyEDID`, `IOMobileFramebufferGetID`, and
`AppleDisplayManagerMappingGet`. Inspection followed their wrappers and the
relevant local kernel components; it did not become a general private-API sweep.

## Reproducible image identity and tools

Host reports macOS 27.0.1 / `26A434`. Shared-cache images:

| Image | Mach-O UUID |
| --- | --- |
| `/System/Library/Frameworks/IOKit.framework/IOKit` | `0E4CF3E4-B0C2-312A-B147-0BD4978EF0B7` |
| `/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer` | `B1C5BB2D-DB25-332B-AD82-CF1EC6170E8B` |

`xcrun dyld_info` reads/disassembles these cache images even though their filesystem
symlink targets are absent. No target function was loaded into a custom caller.
`ipsw` v3.1.730 supplied static stub resolution and kernelcache extraction;
its arm64 macOS archive was fetched with `gh release download` and checked against
the release checksum: `3f50591e4674daf27d2c82a3e9cd4e37ccaa6297197cb5adc6999571859cd321`.
No installation, decompiler service, or remote upload was used.

The local Preboot kernelcache under volume
`716F73E6-876D-40D0-A123-F9036F493311`, boot directory
`DFD211F4285609C0220F74327D4EB27C10DE063B22C729A20CF627EC079E2F076AE8AB59CA9C0B4E4EE14E3DBCDD4C31`,
was decompressed and five relevant kexts extracted with imported symbol names.
Its version matches `uname -v`: `xnu-13432.1.9~1/RELEASE_ARM64_T6050`.
This identifies the inspected local image, not a runtime attestation of driver
instances or connected devices. Decompressed kernelcache SHA-256:
`3132eb048457c1488308166d47c7020b0b1f2858633dfcf6acb745973102366e`.

Evidence directory: `/tmp/panelctl-static-binary.NRnRbjvj/` (0700). It contains
symbol-resolved `edid.asm`, `id.asm`, `mapping.asm`, extracted `kexts/`, and
`dcpav.asm`, `ioav.asm`, `adm.asm`, `iomfb-kernel.asm`, `iomfb-generic.asm`.
Initial dyld-info text is in `/tmp/panelctl-iokit-disassembly.txt` and
`/tmp/panelctl-iomfb-disassembly.txt`. Addresses below are unslid image addresses.

## EDID: user-client → DCP message, not an established fresh hardware read

1. `IOAVServiceCopyEDID` at `0x184e130d4` takes an output pointer, sends selector
   `0x1a` through `IOAVConnectCallCopyMethod`, checks the returned object's type
   against `CFDataGetTypeID`, and writes the data reference to the caller.
   The inspected ABI is status-return plus output pointer, not the one-argument
   CFData-returning third-party declaration found in the source review.
2. The outlined argument setup at `0x184d8eb7c` reads the user-client connection
   from the service wrapper's `+0x14`. `IOAVConnectCallCopyMethod`
   (`0x184e1290c`) calls `IOConnectCallMethod`, then `IOCFUnserializeBinary` on
   the returned serialized bytes. The wrapper does not itself call ReadI2C.
   `IOAVServiceCreateWithService` (`0x184e12eb4`) contains an `IOServiceOpen` call;
   constructing such a wrapper is **not** passive registry inspection.
3. In the extracted IOAV family, `IOAVServiceUserClient::_copyEDID`
   (`0xfffffe000a7c7714`) dispatches to its provider interface and returns the
   resulting object through the external-method output. This is virtual dispatch;
   the user-client handler alone does not identify the concrete producer.
4. The separately inspected DCP implementation,
   `DCPAVServiceProxy::copyEDID(OSObject**)` (`0xfffffe000a140d34`), delegates to
   `DCPAVProxy::__handleVarBytesMsg` with operation `7`. That helper
   (`0xfffffe000a13b6b8`) sends a DCPAVIPC message through `__sendMessage`
   (`0xfffffe000a13b808` call site) and constructs OSData from the returned
   variable-length bytes (`0xfffffe000a13b834–854`). This is the concrete proxy
   implementation relevant to the DCP class previously observed, not proof of
   which runtime object would be selected by a new call.

**Established:** the inspected user-space wrapper performs a user-client request,
and the DCP proxy implementation requests bytes over IPC. **Unknown:** whether
firmware services that request with a new sink transaction, previously acquired
EDID, virtual/override data, or state-dependent behavior. A new IPC response is
not a new physical acquisition. Acquisition time, sink-replacement invalidation,
and logically-offline behavior are not established by these wrappers.

Do not substitute the generic `IOAVService::copyEDID` implementation for the DCP
proxy's firmware-side producer. The exact firmware acquisition/cache lifetime is
the remaining EDID boundary; no observed response or live sink challenge exists.

## Framebuffer ID: concretely cached, not a fresh identity check

`IOMobileFramebufferGetID` (`0x18fefea30`) dispatches through object slot `+0xb28`.
The inspected kernel-backed initializer installs `_kern_GetID` there
(`0x18ff01cd4–ce0`); the virtual-display path also installs it
(`0x18ff07178–184`). `_kern_GetID` (`0x18ff04910`) does this:

```text
lock object mutex
if object.cachedID at +0xad8 is nonzero:
    return cached 32-bit value with success, without a kernel request
otherwise:
    IOConnectCallScalarMethod(connection at +0x14, selector 7, one scalar output)
    on success, store low 32 bits at +0xad8
unlock; write 32-bit ID through caller output pointer
```

This **contradicts treating each successful GetID call as a fresh sink check**.
It does not prove that the ID must change on replacement or that another path
never clears it. The getter itself does not revalidate a populated cache.

In the local kernel components, the named
`IOMobileFramebufferUserClient::s_get_framebuffer_id`
(`0xfffffe000ab9db28`) calls its framebuffer provider and writes a 32-bit result
into the scalar output. `IOMobileFramebufferAP::get_framebuffer_id`
(`0xfffffe000ab7f834`) dispatches an operation with tag `0x41343035` (`A405`) and
four-byte output through its provider interface. These are framebuffer-driver
identifiers; **equivalence or a conversion to CGDirectDisplayID is not established**.
The kernel handler and AP function provide corroborating implementation evidence;
this bounded trace does not claim a complete runtime dispatch-table attestation.

A bounded consumer-side follow-through finds
`CA::WindowServer::IOMFBDisplay::get_framebuffer_id` in QuartzCore at
`0x18b3a1904`: it initializes a 32-bit output to zero, loads its framebuffer
object at `+0x6480`, calls `IOMobileFramebufferGetID` at `0x18b3a1930`, and
returns that output. Retained targeted assembly: `quartzcore-getid.asm` in the
same evidence directory/cache. This identifies a real WindowServer-side
consumer, **not** an offline-CG conversion or lifetime contract. No private
function was invoked. A WIP tool's empty cross-reference result was not treated
as proof of no callers; the symbol-resolved call was found in QuartzCore instead.

`GetServiceObject` (`0x18ff069f0`) simply returns the stored service object at
`+0x10`. Neither it nor a fresh wrapper creates physical-sink identity provenance.

## Display mapping: resource mapping, missing the offline-CG association

`AppleDisplayManagerMappingGet` (`0x18fefe3e4`) dispatches slot `+0x80`.
`AppleDisplayManagerOpen` installs `_kern_DisplayMappingGet` there
(`0x18fefd96c–978`). The implementation (`0x18fefdce8`) calls
`IOConnectCallStructMethod`, selector `8`, expecting a `0x2c1`-byte structure.

The extracted kernel's `AppleDisplayManager::display_resources_mapping_get`
(`0xfffffe00090ef334`) obtains display/resource arrays and calls
`put_disp_mapping_into_output` (`0xfffffe00090eeed8`). The latter iterates
IOAVDisplayConnection objects, counts pipes and fills records containing scalar
fields and a bounded string. This goes beyond an export-name guess, but is not
a documented CG mapping schema. The trace did not establish which scalar field,
if any, corresponds to a CG ID actually returned while offline, nor a shared
sink/CG generation or invalidation contract. Do not infer that from equal values.

## Updated three-part verdict and feasibility boundary

| Candidate | Fresh current physical sink | Independent unique offline-CG association | Replacement / ID reuse / context invalidation |
| --- | --- | --- | --- |
| EDID user-client/DCP proxy path | **Unknown** — transport established, firmware acquisition not established | **Unknown** — no CG join in inspected path | **Unknown** — no cross-boundary lifetime contract |
| Repeated `GetID` as fresh identity proof | **Contradicted** — nonzero cached value bypasses kernel request | **Unknown** — framebuffer namespace, no established CG conversion | **Unknown** — getter does not establish sink or context invalidation |
| AppleDisplayManager mapping | **Unknown** — resource records are not acquisition proof | **Unknown** — no qualified offline-CG association | **Unknown** — no shared generation contract established |

No candidate passes all three. This is a **feasibility blocker for the selected
private-disconnect/re-enable design**, not proof that no monitor-control method
can ever work and not successful completion of the user's shutoff goal.
A setter's existence or a green blackout test does not change that conclusion.
No production provider, unsafe ID fallback, DDC-power fallback, or disable API
was added. A timed helper cannot supply a missing inverse or identity contract.
Any actual shutoff/re-enable test still needs separate explicit approval and a
credible restore/manual-fallback plan; these findings do not yet justify one.
