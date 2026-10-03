# Offline identity — firmware and WindowServer consumers

## Result

**Selected-monitor shutoff with reliable restoration remains a feasibility
blocker. Private re-enable stays blocked.** Both requested binary paths are
statically accessible, but this bounded trace does not establish the fresh sink,
unique enumerated offline-CG association, or shared invalidation contracts.
This is not completion and not proof that every shutoff mechanism is impossible.

This follow-through starts at the two boundaries in
[the earlier binary trace](recovery-identity-binary.md), not its completed
wrapper/kernel transport investigation. No private interface was invoked, no
device client opened, and no display configuration, origin, mode, power,
connection, window, or Mission Control operation was performed.

## Accessible firmware, with a reconstruction limit

The same local Preboot boot directory recorded in the earlier trace contains
`usr/standalone/firmware/FUD/DCP.img4`. Retained `ipsw` v3.1.730 can extract its
IM4P, decompress the BUND payload, and extract an arm64e `dcp.macho` with UUID
`64863924-B56B-3E32-87FE-038677F52709`. This identifies a local boot artifact,
**not an attestation that a particular connected service runs this image**.

SHA-256:

| Artifact | Hash |
| --- | --- |
| extracted `DCP.im4p` | `b32b172ed961566722d45d437e99b30cd4eb6008d7efee1e493a24db5d2133a4` |
| decompressed `dcp.bin` | `d9384573025721074ec1a7190626a8bab36cf61f764055e8e05c7d5d98cb318f` |
| extracted `dcp.macho` | `845605380453e1e429bbd6a5fd0748e2820fc182e423c2ce0e8bf1954a38d340` |

The Mach-O has stripped symbols. `llvm-objdump` disassembles its text;
`ipsw macho info --strings` supplies addressed diagnostic strings. Apple's
`dyld_info -disassemble` crashed on this firmware, and full annotated `ipsw`
disassembly exceeded a 30-second bound; neither failed output is evidence.
LLVM disassembly succeeded. No decompiler service or upload was used.

The extraction is **not yet a validated reconstruction of all data segments**:
for example, the extracted `__DATA_CONST` region at file offset `0xeadb10`
is zero-filled. The original bundle still contains pointer-shaped records,
including the `CopyEDID` string offset `0x8c8ad0` and adjacent code offset
`0xe988c` at bundle offsets `0x109e840` and `0x109e848`. These are candidates,
not a proven relocated dispatch table or operation-7 ordinal. The bundle's
`rdat` range is `0x994000–0x10f0000`; copying candidate offsets into the
Mach-O without validating its layout/fixups would manufacture an association.

### What the text actually establishes

- A routine beginning at `0x40c9db0` references the `copyEDID` diagnostic string
  at `0x48c61f0`. It iterates 128-byte blocks, checks their checksum, and has
  retry/error branches. Its block acquisition call is at `0x40ca020`, to
  `0x40ca79c`. The diagnostic name alone does **not** bind this routine to IPC
  operation 7 or prove acquisition for each request.
- The block helper at `0x40ca79c` checks byte `this+0x78`. When it equals 1,
  it takes bytes from the object at `this+0x70`, bounds-checks the requested
  128-byte block, and copies it. The enclosing routine logs this field as
  `_virtualEDIDMode`. The other branch dispatches through vtable slot `0x628`
  at `0x40ca848`. Its concrete physical byte producer, any lower cache, and
  disconnection/replacement invalidation remain unresolved.
- The code candidate `0x40e988c`, suggested by the original bundle's `CopyEDID`
  record, instead loads an object from `this+0x6d8`, dispatches slot `0x708`,
  and forwards the returned object to `0x411e6b4`. This has **not** been
  conclusively joined to operation 7, the preceding acquisition routine, or
  a specific cache getter. Do not silently substitute one for the other.

**Exact EDID stop boundary:** validated BUND data/fixup reconstruction and
operation-7 receiver → concrete service vtable → returned object's acquisition
and invalidation. The firmware file is available; it would be inaccurate to
report that firmware is unavailable or encrypted beyond inspection. The present
analysis cannot yet supply that chain. Transport remains distinct from freshness.

## Framebuffer consumers are accessible, but not an offline-CG contract

Inspected QuartzCore UUID: `216F70F6-AEF9-3D60-942B-F64C636DEF69`, from the
same local shared cache used earlier. Addresses are unslid.

1. `IOMFBDisplay::get_framebuffer_id` occupies slot `0x88` after the two-word
   vtable header at `0x1e8951ec8`. `-[CAWindowServerDisplay framebufferId]`
   (`0x18b304320`) follows its internal display pointer and dispatches that
   slot at `0x18b304348`; without its backing object it returns `0x10`.
   This is an actual consumer edge, not a search-name inference.
2. A separate `displayId` accessor (`0x18b2fe200`) follows the same internal
   pointer and loads a 32-bit field at `+0x18`; without the backing object it
   returns zero. These distinct access paths do not establish either equality
   or inequality of their values, nor the field's membership in CG enumeration.
3. The actual optimized selector trampoline at `0x19001a860` loads selector
   address `0x1f4f49180` (`framebufferId`) and branches to message dispatch.
   Direct callers in the inspected QuartzCore text include display-wall
   conversion/group matching, resource-configuration conversion, and
   `matching_cawindowserver_display` (`0x18b30b968`). The latter iterates the
   supplied array and returns the **first** object whose `framebufferId`
   equals the input integer, or nil. It does not prove unique sink identity.
4. `getDisplayResourceAllocation` (`0x18b30b43c`) obtains ADM allocation
   records (AllocationGetV2 when available, otherwise AllocationGet), then
   locks its display collection and calls that matcher for each record
   (`0x18b30b710–718`). Matched objects become resource-info objects;
   unmatched records are skipped. This establishes a resource-record → CA
   display-object association. It is **not** the earlier MappingGet schema,
   and it does not enumerate offline CGDirectDisplayIDs.
5. `_initWithDisplays:` retains the supplied array into manager `+0x8`
   (`0x18b30abf0–bf8`) and initializes the lock at `+0x18`. Allocation records
   are fetched before that collection lock (`0x18b30b6dc–6e0`). These local
   lifetime/locking facts do not establish a shared generation with firmware,
   replacement/ID-reuse invalidation, or offline membership of the array.

The inspected direct-trampoline search covered QuartzCore and SkyLight; it
found the listed calls in QuartzCore, not a qualified offline enumeration join.
It is not an exhaustive proof about dynamic dispatch or other images.
The cache symbol table's `_objc_msgSend$framebufferId` address `0x18b446a00`
does not point at that selector trampoline in the inspected bytes and was
**not** used as a caller edge. Empty WIP cross-reference results were likewise
not treated as proof of absent consumers.

**Exact mapping stop boundary:** the retained CA object collection and its
separate `displayId` field → unique ID actually returned by offline CG enumeration,
with replacement, ID-reuse and context invalidation shared with the physical sink.
A resource match and a retained object are not that contract. The cached GetID
finding does not by itself establish unstable identity.

## Evidence and continuation

All new binary artifacts remain beneath `/tmp/panelctl-static-binary.NRnRbjvj/`:
`firmware/{DCP.im4p,dcp.bin,machos/dcp.macho,hashes.txt,edid-strings.txt,
copy-edid-candidate.asm,copy-edid-tail-block.asm,
copy-edid-endpoint-candidate.asm,copy-edid-table-candidate.txt}`;
`quartzcore-{iomfb-vtable.txt,framebuffer-property.asm,displayid.asm,
resource-matcher.asm,resource-allocation.asm,manager-init.asm}`;
`framebuffer-selector-{trampoline.asm,consumers.asm}`. Addressed vtable and
selector-string bytes are in `consumer-addressed-metadata.txt`; firmware UUID,
segments, zero-fill excerpt and bundle ranges are in `firmware/addressed-metadata.txt`.
Full text disassemblies are retained too. Candidate-finding scripts are scratch evidence, not production
code or validated firmware reconstruction tools.

Independent review `899371ed-ab35-459d-9679-7e910768b8e3` found **no validated
findings**, checking the decisive retained assembly and the three-contract
boundary. It did not regenerate firmware metadata/hashes or execute binaries;
those remain parent-attested. Its suggested addressed metadata/string excerpts
were retained afterward. Report: `firmware-consumer-review.md` in the evidence
directory. Documentation whitespace and local-link checks pass.

No source change or runtime test follows from these findings. Previously passed
203 tests/two intentional skips, warnings-as-errors and dual-architecture builds
remain historical results, not reruns. The Mission Control fix remains supporting
blackout functionality; the historical 90% shrink remains unexplained.

The existing clean checkout was adopted at `051bff0` under the user's explicit
continuation request. Original creation receipt and prior Git-local continuations
match the checkout; adoption limitations are recorded in
`.git/worktrees/recovery-enable/continuation-01a10347.json` in the main repository.
No checkout/workspace was created or removed; it remains retained. No push/merge.

The next useful evidence is still static reconstruction/identity-contract work,
not another observer capture or a shutoff trial. No additional live approval is
requested: no concrete restoration-qualified live experiment emerged here.
