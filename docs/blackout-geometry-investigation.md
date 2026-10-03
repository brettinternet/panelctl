# Blackout geometry failure — static investigation

## Authorized runtime follow-through

After explicit permission to run the temporary-window test (but not to change
display configuration), the **unchanged** test passed: once alone, in the full
suite, with all nine geometry tests, and in ten bounded standalone repetitions.
No original 90% mismatch was reproduced. That is current passing evidence, not
proof of a fixed cause or completion of actual monitor shutoff/restoration.

The test now closes its window with `defer`, including on a thrown read failure.
On a real mismatch it records elapsed time, post-order model and compositor
bounds, screen ID, backing scale and active-Space membership at the original
sample and two later samples (50 ms and 200 ms waits). **The first 10 ms sample
still determines failure**; later agreement cannot pass the test. Successful
runs keep the original sampling timing. No production conversion, window sizing,
or display-origin behavior changed.

The diagnostic branch was exercised by temporarily substituting a calculated
90%-size rectangle for the first measured rectangle. The test failed for all
three non-main screens despite subsequent real samples matching. This is a
**synthetic diagnostic injection**, not reproduction of the original OS failure.
The injection was removed immediately; the full suite then passed 205 tests
(203 passed, two intentional skips). All nine geometry tests also passed after
the diagnostic edit. LSP was unknown; compiler warnings-as-errors passed.

Logs: `/tmp/panelctl-geometry-repetitions.log`,
`/tmp/panelctl-geometry-diagnostic-injection.log`, and
`/tmp/panelctl-recovery-final-tests.log`. Live origin-trial and optional ICC-replay
environment variables were unset. No device-client/private-interface invocation,
observer rerun, configuration/origin/mode/power change or connection change ran.
Root cause remains unresolved; no speculative production fix is claimed.

## Original static result and scope

The retained failure is an exact **90% center-preserving size discrepancy** in
WindowServer-reported bounds after ordering the windows. The source conversion
itself preserves size; no origin correction or scale adjustment is justified.
The cause of the compositor/model discrepancy remains **unproven**.

This investigation reads source, Git history, SDK declarations, and the existing
`/tmp/panelctl-connector-followup-full-tests.log` only. Arithmetic below uses its
literal rectangles, not live display data. No XCTest, window creation, display
query, observer, origin trial, configuration change, or binary inspection ran.
This is separate from private re-enable, which remains parked and blocked.

## Retained failure, not a new reproduction

The log records `BlackoutGeometryTests/testWindowPlacementOnConnectedExternalScreens`
failing twice at `BlackoutGeometryTests.swift:60`, on 2026-10-02 at 15:18:10 local
log time. The test ran for 0.087 seconds. No earlier assertion in that test is
reported failing; the pure conversion/content-rect/coverage tests passed in that
same historical run. Those are retained results, not fresh validation.

| Expected Quartz rectangle | Reported compositor rectangle | X/Y size ratio | Shared center | Left/top inset |
| --- | --- | --- | --- | --- |
| `(0,1440,3440,1440)` | `(172,1512,3096,1296)` | `0.9 / 0.9` | `(1720,2160)` | `(172,72)` |
| `(-1440,0,1440,2560)` | `(-1368,128,1296,2304)` | `0.9 / 0.9` | `(-720,1280)` | `(72,128)` |

In both cases, `actual = expected.insetBy(dx: width/20, dy: height/20)`.
This is not merely an origin translation. It affects both axes, on displays
with different shapes and different global origins. The log does not identify
an animation, scale setting, or responsible process.

## Static path

1. `Tests/PanelCtlCoreTests/BlackoutGeometryTests.swift:7–10` selects NSScreens
   whose IDs differ from `CGMainDisplayID`. Despite its name/skip message this
   means **non-main**, not necessarily hardware-external. This naming limitation
   does not explain the recorded bounds discrepancy.
2. `Sources/PanelCtlCore/Blackout.swift:957–989` uses `currentFrame(for:)`, creates
   a borderless window on the selected NSScreen with a zero-origin content rect
   of the target size, configures it, and calls `setFrame(frame, display: false)`.
3. `Blackout.swift:1592–1611` obtains target and main CG bounds and computes:

   ```text
   appKit.x = quartz.minX - mainQuartz.minX
   appKit.y = mainQuartz.maxY - quartz.maxY
   appKit.width  = quartz.width
   appKit.height = quartz.height
   ```

   This is an origin translation / vertical-axis conversion, not scaling. The
   content-rect helper also copies size unchanged. There is no 0.9 factor or
   backing-pixel conversion in this path. Changing main-display height could
   alter Y, but cannot create the two observed size reductions.
4. Test lines 33–40 compare the model frame and screen ID **before ordering**.
   Expected AppKit frame uses the same helper as production; this check alone
   is not independent proof that the helper is correct. Fixed-value conversion
   cases at lines 65–84 provide a separate arithmetic check. Neither observes
   a compositor transform.
5. Lines 42–60 order the window, run the current run loop until 10 ms later,
   fetch that window's `kCGWindowBounds`, and compare it to `CGDisplayBounds`.
   There is no explicit acknowledgment that ordering/composition is complete,
   no second compositor sample, and no post-order `window.frame`/screen-ID log.
   Therefore the retained evidence cannot distinguish a transient presentation
   transform, persistent compositor transform, or post-order model-frame change.

Production coverage checks (`Blackout.swift:929–940`) recheck `window.frame`
after ordering, but do not inspect compositor bounds. Thus passing production
coverage checks does not resolve the failure, and calling it harmless test
flakiness would be premature.

## What the source rules out, and what it does not

- **Simple coordinate-origin error:** cannot by itself explain reduced sizes
  with preserved centers. Do not change the origin formula or display origin
  based on this log.
- **Explicit application scale/resize animation in this path:** not found.
  `configureWindow` sets `.animationBehavior = .none` before ordering. Installed
  AppKit `NSWindow.h:153–164,538–540` says this suppresses automatic AppKit
  ordering animations. Lines 366–369 distinguish animated frame resizing from
  the nonanimated setter used here. An ordinary inferred AppKit animation is
  consequently not an established explanation; an OS/compositor behavior outside
  that contract remains a hypothesis, not a finding.
- **Points-versus-pixels mismatch:** no backing conversion occurs in the source;
  an ordinary integer Retina scale does not explain a 9/10 center-preserving
  transform. Effective platform scaling at the time was not recorded, so this
  does not prove all platform scale explanations impossible.
- **A recovery-branch geometry edit:** neither `Blackout.swift` nor
  `BlackoutGeometryTests.swift` differs between `main` (`e12b2b7`) and reviewed
  `recovery-enable` (`6c00173`). Commit `a6c8401` added the CG-based conversion
  and compositor assertion before this branch. Identical source rules out a
  direct edit here, not an environmental effect or interaction elsewhere.

## Historical stop and integration consequence — superseded by follow-through

The following was the static-only checkpoint. Current passing validation and
the remaining historical uncertainty are recorded at the top of this document.

No production fix, weakened equality, inflated window, longer arbitrary sleep,
or generic regression test is justified by static evidence alone. The full
suite remains **not green**; historical focused recovery/observer passes do not
replace this missing geometry result. Keep that qualification gap visible in
integration review rather than attributing it to offline identity work.

If separately authorized later, the discriminating evidence would be paired
post-order model/compositor bounds with timing and context, sufficient to tell
transient from persistent mismatch. That would create/order windows and is
**not approved or implemented here**. No rerun or display-origin correction is
required to finish this static investigation.
