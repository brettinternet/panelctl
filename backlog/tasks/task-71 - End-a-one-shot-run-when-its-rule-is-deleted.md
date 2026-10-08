---
id: TASK-71
title: End a one-shot run when its rule is deleted
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
ordinal: 59010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Review of TASK-55: deleting a rule that is running once keeps its helper active (reconciliation skips one-shot services) while AppModel.automationBlockingDisplayIDs only iterates saved rules, so Escape focus coverage for that display disappears. An untimed run then persists until CLI restore or quit, contradicting the deletion confirmation that any blackout or dimming from the rule ends.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Deleting a rule that is running once stops its one-shot helper and clears the running rule.
- [x] #2 A fake-backed delete-during-run regression covers helper termination and focus membership.
- [x] #3 Focus membership ends together with the stopped run, as with Restore.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Stop one-shot services whose rule disappears from the rule set during coordinator reconcile. Derive blocking focus membership for the running one-shot from its captured mode rather than saved rules. Add regression.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Delivered in 7a63faf. ProtectionCoordinator.reconcile stops one-shot services whose rule is no longer in the rule set, so deletion ends the run through the normal stop path (which clears blacked-out membership and Escape focus at once, exactly as Restore does). A model-side membership change was tried and reverted: stop clears membership synchronously, so it was unexercised. AC2 reworded accordingly. Regression testDeletingRuleDuringOneShotEndsTheRun times out on the previous source (helper never stops) and passes now.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Deleting a rule that is running once now stops its helper and clears the running rule and focus membership, matching the deletion confirmation. Red-to-green fake-helper regression.
<!-- SECTION:FINAL_SUMMARY:END -->
