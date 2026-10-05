# Display-enable ABI evidence

Static, read-only inspection of the private setter on one OS build. It
establishes the call shape used by the [binding](display-disable.md#mechanism),
not driver acceptance, recovery or permission to call it. A different build
needs new evidence; a symbol name doesn't preserve its ABI.

## Result

```swift
typealias ConfigureDisplayEnabled = @convention(c)
    (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> CGError
```

| Argument | Register | Evidence |
| --- | --- | --- |
| `CGDisplayConfigRef` | `x0`, 64-bit opaque | Validated against the magic written by `CGBeginDisplayConfiguration` |
| `CGDirectDisplayID` | `x1`, stored as `w19` (32-bit) | SDK: `uint32_t` |
| `Bool` | `x2`, bit 0 tested | Pass canonical 0/1 only; other bit patterns are unsupported |
| `CGError` return | `w0`: `0` or `1001` | SDK: `int32_t`; `1001` = illegal argument. Not Swift `Int` |

Use a C function pointer, not `@_silgen_name`. Resolve
`CGSConfigureDisplayEnabled` from CoreGraphics, then `SLSConfigureDisplayEnabled`
from SkyLight.

## Inspected image (2026-10-04)

| Item | Value |
| --- | --- |
| OS / host | macOS 27.0.1 `26A434`, arm64, Apple M5 Max |
| Shared cache | `dyld_shared_cache_arm64e`, UUID `C284A291-B68B-3D0D-A1A0-3F866F87EFDC` |
| CoreGraphics UUID | `B0FB9AC2-E3CC-31C2-A90E-0D38A776BAE2` |
| SkyLight UUID | `8A3B348E-4637-3685-92D0-6CBC2F36A234`, unslid base `0x187093000` |
| Setter | `_SLSConfigureDisplayEnabled`, image offset `0x00198F60`, unslid `0x18722BF60` |
| Tools | Xcode 27.0 (`27A266a`), Apple Swift 6.4, `ipsw` 3.1.730 |

Addresses are unslid virtual addresses, not runtime pointers.

## Reproduce

```sh
cache=/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e
cg=/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics
sl=/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight

sw_vers; uname -m
xcrun dyld_info -uuid "$cg" "$sl"
xcrun dyld_info -exports "$cg" | rg '_CGSConfigureDisplayEnabled|_CGBeginDisplayConfiguration'
xcrun dyld_info -exports "$sl" | rg '_SLSConfigureDisplayEnabled'
ipsw dyld disass "$cache" --symbol _SLSConfigureDisplayEnabled --symbol-image SkyLight --quiet
ipsw dyld disass "$cache" --symbol _SLSBeginDisplayConfiguration --symbol-image SkyLight --quiet
ipsw dyld disass "$cache" --vaddr 0x18722bed4 --quiet     # config validator
```

The first `ipsw` run builds a symbol index; if it can't write beside the system
cache it prints a temporary path. Pass that to later runs with `--cache`.

```text
CoreGraphics: [re-export] _CGSConfigureDisplayEnabled (_SLSConfigureDisplayEnabled from SkyLight)
SkyLight:     0x00198F60  _SLSConfigureDisplayEnabled
CoreGraphics: [re-export] _CGBeginDisplayConfiguration (_SLBeginDisplayConfiguration from SkyLight)
```

Both names reach the same implementation on this cache. `dlsym` names drop the
leading underscore.

## Disassembly

```asm
18722bf60  pacibsp
18722bf84  mov   x20, x0              ; config
18722bf88  cbz   x0, 0x18722c000      ; null → 1001
18722bf8c  mov   x21, x2              ; enabled
18722bf90  mov   x19, x1              ; display ID
18722bf98  bl    0x18722bed4          ; validate config magic
18722bf9c  cbnz  w0, 0x18722c004
18722bfa0  tbnz  w21, #0, 0x18722bfb0 ; enable skips the display check
18722bfa8  bl    0x18722bcb8          ; disable: check display
18722bfac  cbz   w0, 0x18722bfe4
18722bfb0  mov   w0, #0
18722bfcc  stp   w19, w8, [x11]       ; append {id, 2, enabled} entry
18722bfd0  str   w21, [x11, #8]
18722c000  mov   w0, #0x3e9           ; 1001
18722c014  retab
```

`_SLSBeginDisplayConfiguration` (`0x18722BC24`) allocates the config, writes
magic `0xBEEFCAFE`, count at `+8`, capacity at `+12`, entries at `+16`, then
stores the pointer to the caller. The validator at `0x18722BED4` checks that
magic (returning `1001` on mismatch) and grows the entry array. So `x0` is the
begin-produced config, not a display object or pointer-to-pointer. Never
reconstruct this private layout.

## Compile-only cross-check

```c
typedef CGError (*Setter)(CGDisplayConfigRef, CGDirectDisplayID, bool);
CGError call_false(Setter f, CGDisplayConfigRef c, CGDirectDisplayID d) { return f(c, d, false); }
```

```swift
typealias Setter = @convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> CGError
func callFalse(_ f: Setter, _ c: CGDisplayConfigRef, _ d: CGDirectDisplayID) -> CGError { f(c, d, false) }
```

```sh
xcrun clang -arch arm64 -O2 -S binding.c -o binding-c.s
xcrun swiftc -O -emit-assembly binding.swift -o binding-swift.s
```

Both put config in `x0`, ID in `x1`, `#0`/`#1` in `w2`, and tail-call the
pointer; Swift's variable-Bool wrapper adds `and w2, w3, #1`. Nothing was linked
or executed.

## Unknown

Apple's original typedef spelling and behavior for non-canonical booleans. Not
needed for canonical calls.
