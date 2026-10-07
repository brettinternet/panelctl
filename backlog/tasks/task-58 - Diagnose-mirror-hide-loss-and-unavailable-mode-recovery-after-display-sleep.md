---
id: TASK-58
title: Diagnose mirror-hide loss and unavailable-mode recovery after display sleep
status: To Do
assignee: []
created_date: '2026-10-07 03:15'
updated_date: '2026-10-07 03:22'
labels: []
dependencies: []
references:
  - Sources/PanelCtlApp/AppModel.swift
  - Sources/PanelCtlCore/DisplayRecovery.swift
  - Sources/PanelCtlCore/DisplayMirroring.swift
  - docs/display-recovery.md
ordinal: 47010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
On 2026-10-06 with PanelCtl 0.6.1, two displays (AW3425DW and DELL S2721DGF) hidden by public mirroring onto Dell AW3423DW returned as separate desktops after display sleep, with a changed arrangement. Screenshot at 21:10:41 shows both needing recovery and AW3425DW Restore refusing original mode unavailable. User reports manually moving displays in System Settings, without selecting the other offered changes (mirroring, refresh/resolution, input/cable). Current state later matched the baseline. This is a reported failure requiring diagnosis, not proof that strict recovery validation is wrong. Preserve journal and identity protections; no hardware writes or disruptive reproduction are authorized by this task.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Establish the first incorrect transition from captured sleep/wake topology and mode evidence; distinguish mirror loss, layout drift, mode availability, and stale UI errors.
- [ ] #2 Add offline regression coverage for the proven failure and correct it without guessing display identities, approximating modes, replaying DDC input changes, or discarding unresolved journals.
- [ ] #3 Verify the focused tests and document remaining hardware validation gates and any deliberate recovery limitation.
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Read-only investigation (2026-10-06 MDT): pmset logs show display off 20:55:16 and on 21:06:57, with no system Sleep/Wake transition in that interval. SkyLight logs in PanelCtl PID 20596: at 21:06:57 AW3425DW/display 1 inactive, mode 0; K272HUL origin (-1440,0), DELL S2721DGF (3440,-20), versus saved (-1440,5) and (3440,-9). At 21:07:07 display 1 active mode 61 at (0,0), display 2 shifted to (3440,0), display 4 to (6880,-20). Display 1 went inactive again at 21:08:50 and returned at 21:08:52 as mode 103. These logs do not preserve its full available-mode inventory. At 21:10:49.677 PanelCtl committed a forSession public configuration requesting display 1 mode 100 and all original origins; at 21:10:50 logs show those applied. Do not attribute recovery solely to manual dragging: the user reports dragging, but the subsequent app restore is independently logged.

Post-recovery read-only checks: exact AW3425DW baseline mode is available/current: ID 100, logical/pixel 3440x1440, 240 Hz, flags 33554439. All four live positions match baseline. Journal D00CA96D-416D-4C1A-8EED-79847B439132 is verified, trigger system-restoration-verified, both removals restored. No persistent mode-ID mismatch is established. AppModel.resumeSleepHideIntent intentionally only re-hides a fully verified baseline; shifted topology becomes recovery through MirrorController.reconcileSession. Both RecoveryConfiguration.resolveModes and TargetRestoreTransaction.prepareMode require exact RecoveryMode equality. Original-mode-unavailable screenshot may predate the later successful restore; its available modes at failure are unknown.

Validation: swift test --disable-sandbox --filter DisplayHideTests.testTwoDisplayWakeResetOffersGuardedRestoreOfTheCapturedBaseline passed (1 test, 0 failures). This existing fake-backed test already models two mirrors lost with shifted layout and explicit successful Restore; it does not reproduce unavailable-mode failure. No source changes, hardware writes, private setter calls, DDC probes/writes, or live sleep/re-hide actions were performed by this investigation. Missing evidence: full observed topology and current/available CG mode attributes at the refusal, plus lifecycle/intent timeline. Resume diagnosis with a read-only capture before manual correction on recurrence, or a separately user-approved controlled public-mirroring/display-sleep reproduction. Do not relax checks or mark fixed without reproducing the failing transition.

User chose capture next occurrence rather than a controlled reproduction. Leave displays untouched now. Await recurrence; before manual layout correction or Restore, preserve the live journal, read-only app status, display topology, and all current/available CG mode attributes, correlated with sleep/wake timestamps. This is the unblock condition for incident-specific diagnosis, not authorization for hardware writes. Local ignored evidence retained in debug/task58-evidence/: recovery-error.png, post-recovery-journal.json, topology-timeline.log. Screenshot is failure evidence; copied journal is explicitly post-recovery, not the failing journal. Task remains To Do pending recurrence evidence; no implementation claimed or fix delivered.
<!-- SECTION:NOTES:END -->
