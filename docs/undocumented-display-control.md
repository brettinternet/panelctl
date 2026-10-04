# Undocumented selected-display control: recovery-first exploration

## Current direction

This document preserves the initial research and qualification evidence. The
[implementation plan](display-disable-implementation-plan.md) is now the canonical
direction: proceed with bounded offline development and conservative identity
refusal, starting with ABI verification. `backlog/` tracks execution. The gates
below still constrain live writes; they are not a reason to repeat broad research
or permission to bypass an unknown identity.

## Initial recommendation

Investigate macOS-side soft disconnect through `CGSConfigureDisplayEnabled`
first. Do not enable it as a normal feature yet. It avoids deliberately sending
monitor firmware a DDC power command, but neither harmlessness nor reliable
reconnection follows from that distinction. Recovery is the unresolved gate.

This is an exploration, not a qualified implementation. No display-disable,
link-control, power, or DDC commands were executed during this investigation.
[Recovery tooling](display-recovery.md) now implements snapshot/journal handling,
public-configuration restoration, a timed helper, and no-write crash rehearsals.
Private reconnection and safe disable qualification remain future work.

## Read-only host evidence

`swift run panelctl probe --json` built successfully and reported:

- macOS 27.0.1, build 26A434, arm64; system_profiler identified an Apple M5 Max
  Mac Studio.
- Four active external displays: DELL S2721DGF, AW3425DW, K272HUL, and
  Dell AW3423DW (main display).
- `CGSConfigureDisplayEnabled`, `DisplayServicesSetPowerMode`,
  `IOAVServiceGetPower`, `IOAVServiceStartLink`, and `IOAVServiceStopLink` resolve.
- Four `DCPAVServiceProxy` services, but no `AppleCLCD2` matches.

Symbol resolution establishes availability, not a correct ABI, supported target,
safe behavior, or working inverse operation. The older host results in
[feasibility.md](feasibility.md) do not qualify this new host. The missing CLCD
records also mean our existing discovery must be investigated before using it
as a recovery identity source.

## Candidate methods

| Method | Expected effect | Recovery concern | Disposition |
| --- | --- | --- | --- |
| `CGSConfigureDisplayEnabled` / investigated SkyLight equivalents | Remove a display from desktop topology; the monitor may enter normal no-signal standby | Display disappears from normal enumeration; driver may reject enable even with a known ID | First research candidate |
| `IOAVServiceStopLink` / `StartLink` | Names suggest video-link control; per-display behavior not established here | Unverified signatures, service lifetime, pairing, and interaction with WindowServer | Research only; do not invoke based on symbol names |
| `DisplayServicesSetPowerMode` | Private power control, external-monitor support unqualified | No verified external-display restore contract | Lower priority |
| DDC VCP `0xD6` power | Ask monitor firmware to change power state | Monitor may stop accepting wake commands; reports of physical-control failures | Exclude from initial experiment |

Soft disconnect is not guaranteed hardware power-off. Monitor standby and OLED
maintenance behavior must be observed separately. It also moves windows and can
change the main display, unlike the current blackout overlay.

## Evidence and limits

- [displayplacer implementation](https://github.com/jakehilborn/displayplacer/blob/master/src/DisplayPlacer.c)
  calls `CGSConfigureDisplayEnabled(config, displayID, enabled)` and commits
  **permanently**. Its [header](https://github.com/jakehilborn/displayplacer/blob/master/src/Header.h)
  declares a `CGError` return with `CGDisplayConfigRef`, `CGDirectDisplayID`, and
  C `bool` arguments. This is useful implementation evidence, not an Apple ABI
  guarantee. Do not copy the permanent-commit policy into a trial.
- [displayplacer #109](https://github.com/jakehilborn/displayplacer/issues/109):
  the maintainer reproduced disappearing displays on an M2; reports include
  needing a different USB-C port or restarting WindowServer. Retaining the
  original ID fixes only a lookup problem, not driver refusal to reconnect.
- [displayplacer PR #155](https://github.com/jakehilborn/displayplacer/pull/155)
  is open and proposes numeric IDs plus attempts to enable IDs in a small
  range. Blind ID sweeps are not a suitable targeted recovery strategy.
- [Lunar FAQ](https://lunar.fyi/faq) describes a hidden disconnect API on
  Apple Silicon/macOS 13+. This demonstrates feasibility, not qualification of
  our implementation. Lunar's public repository says its Pro implementation
  is encrypted; the exact disconnect/recovery implementation was not verified.
- [BetterDisplay #1623](https://github.com/waydabber/BetterDisplay/issues/1623)
  documents recovery failures and a subtle guard failure: macOS can create a
  headless virtual display that still counts as online. An online-display count
  is not proof that another usable physical screen remains.
- [BetterDisplay #5658](https://github.com/waydabber/BetterDisplay/issues/5658)
  contains model-specific built-in-display failures and a maintainer warning
  for base-M3 laptops. These are not evidence that this M5 Max/external-display
  setup fails, but they disprove universal easy-recovery claims.
- [ddcctl #89](https://github.com/kfix/ddcctl/issues/89) contains reports of
  physical controls failing and monitors requiring power removal after power
  commands. The original report also used another flag and does not isolate a
  single cause. Nevertheless, DDC power is a poor fit for this safety goal.

## Qualification gates before a live trial

1. **Define restoration.** Capture all displays' identities, connector mapping,
   modes/refresh rates, rotation, origin, main-display and mirroring state, plus
   HDR/color state where accessible. Current `DisplayRecord` is insufficient.
   Restoring connectivity does not guarantee exact application-window/Spaces
   placement; that is a separate acceptance criterion.
2. **Establish identity outside online enumeration.** Retain pre-disable ID and
   UUID plus hardware/connector evidence. Investigate current IOKit classes.
   Do not assume IDs persist across hotplug or enable an ambiguous new device.
3. **Verify ABI and transaction scope.** Resolve symbols dynamically and fail
   closed if unavailable. Investigate temporary/app-scoped configuration and
   its actual behavior for the private setter. Do not assume process exit
   reverses it; no permanent configuration writes in an initial trial.
4. **Implement recovery before disable.** Persist a restoration journal and arm
   an independent helper before mutation, with a short rollback deadline and
   a restore command that works without finding the target in the online list.
   Simulate parent exit/crash and restore errors first. A helper can survive a
   CLI crash, but cannot guarantee recovery from WindowServer/driver failure.
5. **Constrain the first trial.** Explicit consent, one non-main external
   display, another verified usable physical display left on, no mirroring,
   no automatic startup behavior, no concurrent topology changes. Agree on
   acceptable physical fallback first; do not silently escalate to session
   termination, preference deletion, or reboot.
6. **Verify restoration, not just return codes.** Compare restored topology and
   mode with the snapshot, verify visible output with the user, and separately
   confirm actual monitor standby. A successful API return is not sufficient.
   Stop on the first unexplained mismatch rather than repeatedly toggling.
7. **Qualify incrementally.** Test crash and sleep/hotplug interactions only
   after a simple off/on cycle succeeds, with separate consent for disruption.
   Keep qualification scoped to OS build, Mac, monitor, firmware, and connection
   path; requalify after relevant changes.

If cable replugging or rebooting is unacceptable even for the first experiment,
we should stop before live soft-disconnect calls. Research and rollback tooling
can reduce risk, but cannot prove an untested private driver path recoverable.
