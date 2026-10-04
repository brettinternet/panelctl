# Display-enable ABI: bounded offline evidence

TASK-1, inspected 2026-10-04 UTC. **Go for the TASK-4 binding below on this
inspected build only; no hardware qualification or permission to call it.**
This is fresh local evidence, separate from the historical
[tool survey](display-disable-tool-survey.md). The
[implementation plan](display-disable-implementation-plan.md) remains canonical.

## Host and image identity

| Item | Observed value |
| --- | --- |
| OS | macOS 27.0.1, build `26A434` |
| Host | `arm64`, Apple M5 Max |
| Cache | `/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e` |
| Cache UUID / format | `C284A291-B68B-3D0D-A1A0-3F866F87EFDC`, `dyld_v1 arm64e`, 79 subcaches |
| CoreGraphics UUID | `B0FB9AC2-E3CC-31C2-A90E-0D38A776BAE2` (`arm64e`) |
| SkyLight UUID | `8A3B348E-4637-3685-92D0-6CBC2F36A234` (`arm64e`) |
| SkyLight image base | unslid `0x187093000` |
| Setter | `_SLSConfigureDisplayEnabled`, image-relative `0x00198F60`, unslid `0x18722BF60` |
| Tools | Xcode 27.0 (`27A266a`); Apple clang 21.0.0 (`clang-2100.3.34.2`); Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), arm64 target |
| Static inspector | `ipsw` 3.1.730, build `96d398680cd467f22f07bebb34b6aca43e3e27fb` |

Framework paths used were `/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics`
and `/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight` (cache images,
not copied framework binaries). Addresses below are **unslid virtual addresses**,
not runtime pointers or offsets into a cache file.

Tool SHA-256:

- Xcode `dyld_info`: `1312aaaac28bd7636fcd1b9347328db80003de8f6da27a03126b0ae716c3cf62`
- retained `ipsw`: `aed7ec464524f2bd6d51c0f85ceeeab665a0c6dae13f9ef586f44206a2a6bd46`

## Reproduction (read-only inspection)

These are shell-local convenience names, not display IDs. The retained inspector
was already available at the path below; no surveyed app was installed or run.
If it is gone, use the identified inspector version rather than treating missing
tooling as verification. Do not reuse these addresses on another cache UUID.

```sh
sw_vers
uname -m
sysctl -n machdep.cpu.brand_string
xcodebuild -version
xcrun clang --version
xcrun swiftc --version
xcrun --find dyld_info
xcrun --show-sdk-path

abi_ipsw=/private/tmp/panelctl-static-binary.NRnRbjvj/ipsw
abi_cache=/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e
abi_cg=/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics
abi_sl=/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight
"$abi_ipsw" version
shasum -a 256 "$abi_ipsw" "$(xcrun --find dyld_info)"
"$abi_ipsw" dyld info "$abi_cache"
xcrun dyld_info -uuid "$abi_cg" "$abi_sl"
xcrun dyld_info -segments "$abi_sl"
xcrun dyld_info -exports "$abi_cg" | rg '_CGSConfigureDisplayEnabled|_CGBeginDisplayConfiguration'
xcrun dyld_info -exports "$abi_sl" | rg '_SLSConfigureDisplayEnabled'
"$abi_ipsw" dyld disass "$abi_cache" --symbol _SLSConfigureDisplayEnabled --symbol-image SkyLight --quiet
```

The first `ipsw` invocation generated a symbol index, could not write it beside
the protected system cache, and reported its temporary fallback:
`/var/folders/jp/1mwx72h172955139pth4h8800000gn/T/C284A291-B68B-3D0D-A1A0-3F866F87EFDC.a2s`.
Subsequent disassembly commands used `--cache` with that reported path. On another
run use the path it reports. Local/private symbols are absent; the helper below
is identified by address, not a recovered source name. No extraction was needed.

Only the directly necessary configuration producer and validator were followed:

```sh
abi_symbols=/var/folders/jp/1mwx72h172955139pth4h8800000gn/T/C284A291-B68B-3D0D-A1A0-3F866F87EFDC.a2s
"$abi_ipsw" dyld disass "$abi_cache" --symbol _SLBeginDisplayConfiguration --symbol-image SkyLight --quiet --cache "$abi_symbols"
"$abi_ipsw" dyld disass "$abi_cache" --symbol _SLSBeginDisplayConfiguration --symbol-image SkyLight --quiet --cache "$abi_symbols"
"$abi_ipsw" dyld disass "$abi_cache" --vaddr 0x18722bed4 --quiet --cache "$abi_symbols"
```

`dyld_info -help` is unsupported here; `man dyld_info` documents the available
options. Its `-disassemble` covers whole code sections, so symbol-bounded `ipsw`
was used instead. No identity, firmware, driver, or downstream server research
was reopened.

## Export relationship and relevant instructions

`dyld_info -exports` reports:

```text
CoreGraphics: [re-export] _CGSConfigureDisplayEnabled (_SLSConfigureDisplayEnabled from SkyLight)
SkyLight:     0x00198F60  _SLSConfigureDisplayEnabled
CoreGraphics: [re-export] _CGBeginDisplayConfiguration (_SLBeginDisplayConfiguration from SkyLight)
```

Thus CoreGraphics's `CGS` name and the direct SkyLight `SLS` fallback reach the
same implementation on this cache, not two independently verified setters.
Mach-O listings use a leading underscore; `dlsym` names do not.

Selected instructions from the complete inspected setter (`0x18722BF60` through
`0x18722C06C`; gaps below are omitted, not contiguous code):

```asm
18722bf60  pacibsp
18722bf84  mov   x20, x0
18722bf88  cbz   x0, 0x18722c000
18722bf8c  mov   x21, x2
18722bf90  mov   x19, x1
18722bf94  mov   x0, x20
18722bf98  bl    0x18722bed4
18722bf9c  cbnz  w0, 0x18722c004
18722bfa0  tbnz  w21, #0, 0x18722bfb0
18722bfa4  mov   x0, x19
18722bfa8  bl    0x18722bcb8
18722bfac  cbz   w0, 0x18722bfe4
18722bfb0  mov   w0, #0
18722bfb4  mov   w8, #2
18722bfb8  ldr   x9, [x20, #0x10]
18722bfbc  ldrsw x10, [x20, #8]
18722bfc0  lsl   x11, x10, #5
18722bfc4  sub   x10, x11, x10, lsl #2
18722bfc8  add   x11, x9, x10
18722bfcc  stp   w19, w8, [x11]
18722bfd0  str   w21, [x11, #8]
18722bfd4  ldr   w8, [x20, #8]
18722bfd8  add   w8, w8, #1
18722bfdc  str   w8, [x20, #8]
18722bfe0  b     0x18722c004
18722c000  mov   w0, #0x3e9
18722c004  ldp   fp, lr, [sp, #0x30]
18722c008  ldp   x20, x19, [sp, #0x20]
18722c00c  ldp   x22, x21, [sp, #0x10]
18722c010  add   sp, sp, #0x40
18722c014  retab
```

The false path has a display check at `0x18722BCB8`; its failure logs and returns
`1001`. It was not followed: this task establishes the call ABI, not disable
eligibility. The entry also tests initialization state and has an assertion path;
no experiment with null/fabricated configurations is safe or required.

The configuration connection is more than a guessed pointer type:
`_SLBeginDisplayConfiguration` at `0x1871F68A8` branches to
`_SLSBeginDisplayConfiguration` at `0x18722BC24`. That producer stores magic
`0xBEEFCAFE` through its allocated pointer (`0x18722BC5C–BC64`), initializes the
count at `+8`, capacity at `+12`, and entry-array pointer at `+16`, then writes
the configuration pointer to the caller's output (`str x20, [x19]` at `BCA0`).
The setter's direct helper `0x18722BED4` loads `[x0]`, checks that same magic,
returns `1001` in `w0` on mismatch, and ensures entry capacity using those same
fields; its normal returns set `w0 = 0`. This ties the setter's `x0` to the
public begin-produced configuration, not a display object or pointer-to-pointer.

## ABI findings and compile-only cross-check

| Fact | Evidence / supported interpretation |
| --- | --- |
| Configuration | First argument `x0`: 64-bit opaque `CGDisplayConfigRef`, as established by the producer/validator chain above. Never reconstruct the private layout. |
| Display ID | Second argument `x1`, consumed/stored as `w19` (32 bits). SDK `CGDirectDisplay.h` defines `CGDirectDisplayID` as `uint32_t`. |
| Boolean | Third argument `x2`, bit 0 tested as `w21`; 32-bit payload stored. Pass canonical **0 or 1**, zero-extended in `w2`, as emitted for C `bool` / Swift C-convention `Bool`. The 32-bit internal slot does not imply a 32-bit source-language boolean. |
| Calling convention | C arm64 register arguments, preserved callee-save registers, `w0` return; arm64e implementation uses `pacibsp` / `retab`. Use a C function pointer, not a Swift `@_silgen_name` declaration. |
| Return | All normal setter paths produce or forward a 32-bit `w0`: `0` or `1001` in the inspected paths. SDK `CGError.h` defines `CGError` with `int32_t` underlying type, success `0`, illegal argument `1001`. Not Swift `Int`. |

Disassembly does not recover Apple's original private typedef spelling (e.g.
`bool` versus an equivalent canonical integer parameter), nor establish behavior
for noncanonical boolean bit patterns. Those are **unknown and unsupported**,
not required for the exact canonical 0/1 binding. It does establish the machine
call shape needed by that binding.

Compile-only checks used local files `binding.c` and `binding.swift` under
`/tmp/panelctl-abi-task1.8g3T00ZP`. No linking, symbol resolution, or execution of
these fixtures occurred. To reproduce, save these snippets in a scratch directory:

```c
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
_Static_assert(sizeof(CGDisplayConfigRef) == 8, "pointer");
_Static_assert(sizeof(CGDirectDisplayID) == 4, "display ID");
_Static_assert(sizeof(CGError) == 4, "error");
_Static_assert(sizeof(bool) == 1, "C bool");
typedef CGError (*Setter)(CGDisplayConfigRef, CGDirectDisplayID, bool);
CGError call_binding(Setter f, CGDisplayConfigRef c, CGDirectDisplayID d, bool b) {
    return f(c, d, b);
}
CGError call_false(Setter f, CGDisplayConfigRef c, CGDirectDisplayID d) {
    return f(c, d, false);
}
CGError call_true(Setter f, CGDisplayConfigRef c, CGDirectDisplayID d) {
    return f(c, d, true);
}
```

```swift
import CoreGraphics
public typealias Setter = @convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> CGError
public func callBinding(_ f: Setter, _ c: CGDisplayConfigRef, _ d: CGDirectDisplayID, _ b: Bool) -> CGError {
    f(c, d, b)
}
public func callFalse(_ f: Setter, _ c: CGDisplayConfigRef, _ d: CGDirectDisplayID) -> CGError {
    f(c, d, false)
}
public func callTrue(_ f: Setter, _ c: CGDisplayConfigRef, _ d: CGDirectDisplayID) -> CGError {
    f(c, d, true)
}
```

```sh
xcrun clang -arch arm64 -O2 -S /tmp/panelctl-abi-task1.8g3T00ZP/binding.c -o /tmp/panelctl-abi-task1.8g3T00ZP/binding-c.s
xcrun swiftc -O -emit-assembly /tmp/panelctl-abi-task1.8g3T00ZP/binding.swift -o /tmp/panelctl-abi-task1.8g3T00ZP/binding-swift.s
```

Both compiled successfully. Both constant wrappers move the configuration into
`x0`, display ID into `x1`, set `w2` to `#0` / `#1`, and tail-branch through the
function pointer. Swift's variable wrapper additionally emits `and w2, w3, #1`.
This confirms the supported Swift type lowers to the observed C call boundary;
it does not substitute for the local implementation disassembly.

## TASK-4 handoff and limits

Supported binding for this build:

```swift
typealias ConfigureDisplayEnabled = @convention(c)
    (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> CGError
```

Resolve `CGSConfigureDisplayEnabled` dynamically from CoreGraphics first, then
`SLSConfigureDisplayEnabled` from SkyLight. Keep the owning library handle alive
for the pointer lifetime. Symbol presence alone is not ABI verification. TASK-4
must fail closed when the binding cannot be resolved or the OS/architecture/image
identity is outside verified evidence; a different build needs new bounded proof,
not an assumption that the symbol name preserves its ABI. This note adds no
resolver or runtime allowlist to main.

No required machine-ABI fact remains unknown for canonical calls on the recorded
host. **No-go for live use now:** ABI compatibility does not prove driver acceptance,
retained-ID identity, recovery, signal loss, input switching, or watchdog safety.
TASK-4 still needs its transaction/error tests and the other plan gates. Use only
fake writers during offline development, session-only commits when eventually
authorized, cancellation before completion on setter error, and never cancellation
after completion. Any unresolved ABI fact on a later target keeps its backend
unavailable.

Validation here consisted of fresh export/UUID inspection, complete setter and
bounded producer/helper disassembly, SDK type comparison, and compile-only C/Swift
checks. No panelctl command, surveyed application, private setter (including
true-only enable), display transaction, DDC write, or disruptive recovery was run.
Only text evidence is committed; no Apple binaries, cache index, display identity
or serial dump is included. The temporary compiler fixtures/assembly and generated
symbol index are disposable local evidence, not runtime dependencies.
