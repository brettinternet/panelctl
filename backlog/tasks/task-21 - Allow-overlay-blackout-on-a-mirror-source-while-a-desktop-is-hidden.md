---
id: TASK-21
title: Allow overlay blackout on a mirror source while a desktop is hidden
status: To Do
assignee: []
created_date: '2026-10-04 18:22'
updated_date: '2026-10-04 18:22'
labels:
  - display-hide
  - app
  - protection
dependencies:
  - TASK-17
references:
  - Sources/PanelCtlCore/Blackout.swift
  - Sources/PanelCtlApp/ProtectionService.swift
  - docs/display-hide-ux.md
priority: medium
type: feature
ordinal: 11010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
While a desktop is hidden by mirroring (TASK-13/15/17), blackout refuses every display in the mirror set because validateTarget checks CGDisplayIsInMirrorSet, which is true for the mirror source as well as the mirrored target. The TASK-16 contract therefore pauses app protection for the whole hide or handoff. In the recorded setup the source is the OLED AW3423DW. During a handoff the user is usually on the other computer while the Mac sits idle on a static desktop, so the OLED is unprotected exactly when protection matters most. This task decides whether blackout can safely cover a mirror-set source, and implements that if so. The overlay would also appear on the mirrored target: harmless on a handed-off input, visible black on a plain hide. Brightness dimming of the target, or of the source through DDC, risks fighting the hide/show transaction. Hide/show ownership, locks and the journal stay unchanged. Offline implementation and fake/no-write validation only; any live blackout of a mirrored display or topology write needs fresh scoped human approval.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 An updated docs/display-hide-ux.md coexistence contract, approved by the user, states which displays in a PanelCtl-owned mirror set may receive overlay blackout. It also covers what the mirrored target shows and why brightness dimming stays excluded or is safe. If the conclusion is that it cannot be made safe, that conclusion and its evidence are recorded instead, and the remaining criteria are dropped.
- [ ] #2 Blackout allows only the approved mirror-set displays, and only while observed state is Hidden by PanelCtl, verified against the shared journal. External mirrors, recovery-needed, busy hide/show and stale or unknown topology keep the existing refusal.
- [ ] #3 Overlay protection never makes topology, DDC input or brightness writes, and is quiesced before Show capture and verification. Show and recovery remain reachable and keyboard-accessible over an active overlay, and activity or Restore never triggers Show.
- [ ] #4 Hide confirmation and protection status copy are updated to match the new behavior; nothing claims protection that does not occur.
- [ ] #5 Fake tests cover the allowed source, refused external mirror, refused recovery-needed or busy state, topology change during overlay and Show while overlaid; relevant tests and warnings-as-errors builds pass.
<!-- AC:END -->
