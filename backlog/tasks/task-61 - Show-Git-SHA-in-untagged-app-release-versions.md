---
id: TASK-61
title: Show Git SHA in untagged app release versions
status: Done
assignee:
  - '@pi'
created_date: '2026-10-07 20:34'
updated_date: '2026-10-07 20:35'
labels: []
dependencies: []
ordinal: 50010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Local release builds currently look identical in General settings, making installed development builds hard to identify.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Untagged packaged builds show semver followed by the short HEAD SHA in the existing General version field.
- [x] #2 Matching tagged releases retain their plain release version, including prereleases; regression tests cover both paths.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Extend release-version.sh to derive the display version from the matching tag and HEAD; use it for PanelCtlReleaseVersion during packaging. Add isolated Git-fixture tests and verify generated plist values without presenting native UI.
<!-- SECTION:PLAN:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Packaging now appends the short HEAD SHA to PanelCtlReleaseVersion unless HEAD matches the requested release tag. General settings already displays this field; numeric bundle versions are unchanged. Verified scripts/test-release-version.sh with disposable Git fixtures for untagged, unrelated tag, lightweight release tag, annotated prerelease, later commits and detached tagged HEAD, plus plist round-trips. Bash syntax checks, shell LSP diagnostics and git diff --check pass. No native UI was presented.
<!-- SECTION:FINAL_SUMMARY:END -->
