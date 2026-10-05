# Supervised DELL S2721DGF trial — 2026-10-05

## Before writes

- Implementation: `8ce614e4a5ddd599f0fceeb56fe691d64b494125`.
- Host: Mac17,14, arm64, macOS build 26A434.
- Target freshly enumerated: DELL S2721DGF, firmware **M3T101** (user-reported), UUID `09084682-3C42-4455-AAB8-126A7431125B`, CG ID 1, vendor 4268/model 16857/serial 1094800204.
- Connection: `Port-USB-C@3/DisplayPort`, framebuffer `dispext3@4000000`; HPD High, transport active. Mac on DP, other computer awake on HDMI, confirmed by user.
- Baseline: 1440×2560 pixels, 165 Hz, mode 75, rotation 270°, origin (3440,-4).
- Survivor: main Dell AW3423DW, ID 5, 3440×1440 at 175 Hz; user confirms usable throughout. K272HUL and AW3425DW also qualify as physical survivors.
- No-write preflight: identity eligible, awake, nativeOnly (four online displays mapped uniquely to five Apple DCP slots, 269 Apple kexts, zero system extensions), no mirroring. Two production-provider tests passed; CLI build passed.
- No-write helper rehearsal: 5 seconds, journal `~/Library/Application Support/PanelCtl/Recovery/task-9-rehearsal-20261005.json`, ID `D4612713-9167-4AB4-9CBD-BF039C597312`, helper PID 92803, state verified, trigger deadline. This does not qualify private recovery.
- Private trial journal: `~/Library/Application Support/PanelCtl/Recovery/task-9-cycle-20261005.json`. Existing resolved default journal is untouched.
- Explicit scoped user consent: **one 15-second session-only disable/re-enable cycle**, including bounded public topology restoration if required. User is present; survivor usable; no concurrent topology/input automation, mirroring, hotplug or sleep.
- Private helper must independently acknowledge READY and persist armed/deadline before the parent requests disable; existing CLI enforces both, and helper performs all writes. Actual private helper evidence pending execution.
- Agreed fallback: stop on the survivor and manually select DP using monitor controls if necessary. Preserve evidence. No automatic DDC, global reset, logout, reboot or cable changes. Same-port replug is not guaranteed recovery.
- Disclosed limits: windows, Spaces, HDR and full color calibration are not restored; rotation is checked, not written. Exact topology/modes and user-visible output must both be checked.

## Observations

First command refused before journal creation, helper arming or display writes:
`unverified ABI image for CGSConfigureDisplayEnabled`. Read-only inspection found
both recorded image UUIDs matched, but dyld/dladdr used exact `Versions/A` paths
while the resolver compared unversioned aliases. Evidence retained in
`~/Library/Application Support/PanelCtl/Recovery/task-9-evidence-20261005`.

User approved correcting the resolver offline, with tests and independent review,
then separately approved **one corrected 15-second attempt**, reconfirming all
setup and fallback conditions above. No successful live cycle claimed yet.

The fix uses the exact versioned install names, keeping UUID, origin, build and
architecture checks unchanged. Nine binding tests pass, including read-only real
resolution and rejection of unversioned, wrong-version and relocated origins.
Focused core recovery tests: 96 tests, one skip, zero failures. Both products
build with warnings-as-errors. Independent reviewer
`135a6828-9610-49b3-ba58-9b579084edde` found no validated defects (one review pass).
LSP: source report initially unknown; test file clean. `git diff --check` passes.

Full-suite limitation: app ProtectionPreferencesTests reports 33 assertions
failed (three unexpected); a representative failure reproduces on unchanged
main. A broad recovery-name filter also selects app tests and crashes in
DisplayHideAppTests at line 1882. These are not claimed fixed; core-only recovery
checks pass. No further general review or unrelated cleanup was performed.

## Corrected cycle result

**Qualified only for this physical unit/firmware/host/build/connection and one
supervised cycle, with manual DP input selection required on return.** This is
not a reliability claim or qualification of unattended operation.

- Executed implementation: `2431c17` (only source/test changes from `8ce614e`).
- Private journal ID: `F602F78F-CDD1-4E82-912F-787B5ED90001`; helper PID 67898.
- Captured at 2026-10-05 19:47:07.727 UTC; deadline 19:47:22.727 UTC.
- Observer saw `armed` at 19:47:07.813 before `disabling` at 19:47:08.925,
  staged at 19:47:09.615, commit intent at 19:47:09.990 and `disabled` at
  19:47:10.263. READY is enforced by the parent protocol, not separately logged.
- Deadline recovery intent (`reenableAttempted`) observed at 19:47:23.915;
  `restored` at 19:47:27.086, with private authority closed. These are sampled
  journal timestamps, not exact setter timings; the 15-second deadline initiates
  recovery rather than guaranteeing visible output within 15 seconds.
- CLI exit 0, no failure diagnostic: disable and retained-ID enable accepted.
  Public restoration is allowed if needed but is not separately recorded in the
  journal, so its actual invocation is not claimed.
- During disable, ID 1 disappeared from public enumeration; IDs 2, 3 and 5
  remained active. Main temporarily moved to AW3425DW and origins shifted.
  After recovery, enumeration and bounds matched the baseline exactly, including
  AW3423DW as main. All recorded exact modes/topology passed journal verification.
- User observed **automatic HDMI selection** to the other computer. Whether a
  no-signal message or standby indication preceded HDMI is **uncertain**.
- Monitor **stayed on HDMI after recovery**. User manually selected DP and
  confirmed normal portrait layout/usable Mac output; the AW3423DW survivor
  remained usable. No unexplained visible mismatch was reported.
- Target transport snapshots before/during/after retained registry ID 4294977716,
  HPD High, Active true and link-rate label 8.1 Gbps (HBR3). These cached metadata
  fields did not track public removal: they do **not** prove electrical link
  shutdown. User-observed HDMI auto-selection establishes the practical result.
- A separate `recovery verify --journal <trial-path>` exited 0 after the cycle
  without display writes. The private journal is resolved; it is retained.

## Retained evidence and limits

Raw before/during/after enumeration, transport plists, sampled journal
transitions, command stdout/stderr/exit and final journal remain at
`~/Library/Application Support/PanelCtl/Recovery/task-9-evidence-20261005-corrected`.
The original refused attempt and no-write rehearsal remain separate. Local test
logs use `/tmp/panelctl-task9-*.log`; durable conclusions are recorded here and
in TASK-9. The creation receipt belongs to Pi session
`01a10aad-8e5a-7226-b088-b77fdd31b225`, branch `task-9-supervised-trial`.

The success covers software connectivity/mode restoration and visible output
**after manual input selection**. It does not cover automatic DP return, window
placement, Spaces, HDR, full color calibration, repeated trials, or other tuples.
The existing DDC input-selection work may address return focus separately; no
DDC action was performed or authorized by this trial.

Global restore alone, logout, reboot, hotplug, crash, sleep and DDC trials are
**untested and not authorized**. No further toggle was performed after success.
