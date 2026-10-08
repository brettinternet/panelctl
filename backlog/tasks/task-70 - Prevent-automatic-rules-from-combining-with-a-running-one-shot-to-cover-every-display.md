---
id: TASK-70
title: >-
  Prevent automatic rules from combining with a running one-shot to cover every
  display
status: Done
assignee: []
created_date: '2026-10-08 05:43'
updated_date: '2026-10-08 05:53'
labels: []
dependencies: []
references:
  - Sources/PanelCtlApp/AppModel.swift
  - Sources/PanelCtlApp/ProtectionCoordinator.swift
type: bug
ordinal: 58010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Review of TASK-55: automatic scheduling during a one-shot only checks display overlap. With disabled rule A running once (blocking, until activity) on one display, enabling disjoint rule B (until activity) on the other lets B start, so together they can black out every display indefinitely — the configuration combined-coverage validation normally rejects. Admission validation ignores A because it is saved as disabled.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 While a one-shot runs, an automatic rule whose validation fails when the one-shot rule is counted as enabled does not start, and its status explains it is waiting for the one-shot to finish.
- [x] #2 The deferred rule starts automatically after the one-shot finishes, and saved preferences are unchanged.
- [x] #3 A fake-backed regression covers enabling a disjoint untimed rule during a disabled untimed one-shot.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
In AppModel.reconcileProtection, gate each enabled automatic rule on a second validation in which running one-shot rules count as enabled; keep normal arguments when it passes, otherwise withhold arguments and report a waiting reason. One-shot completion already reconciles and resumes rules. Add regression in ProtectionRuleRunOnceTests.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Delivered in 9f8051d. AppModel.reconcileProtection revalidates each runnable automatic rule with the running (saved-disabled) one-shot rule counted as enabled; failures withhold the rule's arguments and set a waiting reason (“<name>” is running once; this rule starts when it finishes.). Normal arguments are kept when the gate passes, so non-conflicting rules are unaffected. Existing one-shot completion reconcile/resume starts the deferred rule. Regression testDisjointUntimedRuleCannotCombineWithUntimedOneShotToCoverEveryDisplay fails on the previous source (rule B launched) and passes now; it also checks the row headline, later automatic start and unchanged preferences apart from the user's enable.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Automatic rules can no longer combine with a running disabled one-shot to black out every display indefinitely; they wait with an explanatory status and start after it ends. Red-to-green fake-helper regression.
<!-- SECTION:FINAL_SUMMARY:END -->
