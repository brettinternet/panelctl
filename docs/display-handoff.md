# Away / back monitor handoff (TASK-15)

One command hides a monitor's separate Mac desktop and optionally switches its
input to another computer; the other restores the desktop and optionally selects
the Mac input. This uses public mirroring, **not private display disable**. The
combined hardware round trip is not yet qualified; previous independent DDC and
mirroring trials do not qualify their combination.

## Commands

After fresh scoped approval, discover current selectors with `panelctl list`.
Prefer UUIDs, not changing indices. The target must be non-main, external, online,
active and awake; the explicitly selected mirror source must be distinct, active,
online and awake. Existing mirrors and ambiguous selections are refused.

```text
panelctl away --display <target-uuid> --source <source-uuid> --input hdmi1 --consent-away
panelctl back --display <target-uuid> --input dp1 --consent-back
```

Both accept `--journal <path>` and must use the same journal. The default is the
shared recovery `~/Library/Application Support/PanelCtl/Recovery/current.json`.
A custom parent directory must be user-owned and mode 0700. `back` refuses a
target that differs from the journal's target, including a changed ID/UUID.
It can restore an existing `mirror` journal too; it never captures over it.

`--input` is optional and independent for each command. It accepts `dp1`, `dp2`,
`hdmi1`, `hdmi2`, decimal 1–255 or hexadecimal values, using the same mapping as
[ddc-input](ddc-input.md). Omit it to make **no DDC requests at all**. With it,
DDC is skipped if the channel cannot be opened or a valid nonzero current input
cannot be read. The message tells the user to use the monitor's input button.
A successful read does not prove the monitor accepts input writes.

Without DDC, away/back still hide/unhide the desktop; switch inputs manually.
Mirroring keeps the Mac sending a signal, so these monitors are **not expected
to switch automatically**. Non-DDC hardware behavior has not been observed for
these commands. Private signal-drop work remains parked, not a hidden fallback.

## Ordering and failures

- Away: resolve and validate target/source → capture and durably save topology
  → optional DDC input selection → revalidate topology → mirror and verify.
  Capture/journal failure prevents both input and topology writes.
- Back: bind selection to the saved target → restore and verify topology
  → optional DDC input selection. An unavailable or failing DDC step cannot
  prevent unhiding; a failed unhide prevents the subsequent input write.
- Existing operation/journal locks cover the entire sequence. DDC uses the
  journal target UUID and checks the opened ID/UUID, never a reinterpreted index.
  Other display applications do not honor these advisory locks.
- DDC selects at most once, with bounded readback and no retry. `unverified`
  means the write was attempted but readback was unavailable, not that the input
  definitely changed. Away continues to hide in that case; check visually.
  A thrown DDC write/readback-mismatch error stops away before mirroring.
- Before input selection, output includes the exact command restoring the
  previously read input (and the physical input button fallback). If mirroring
  then fails, the error repeats this command along with the journal-specific
  public recovery command. There is no automatic rollback or repeated toggle.
- A DDC error on back leaves the desktop already restored and reports input
  recovery. A topology error retains unresolved evidence and prints
  `panelctl recovery restore --journal '<actual-path>'`. Inspect `recovery status`
  before explicitly approved recovery; missing/changed identity, rotation or
  color can require manual correction. Never erase an unresolved journal.

Input recovery is printed, not persisted in the topology journal. Keep the
output; after abrupt termination use the monitor's input button if the original
input is unknown. The journal still permits public topology recovery under its
normal checks. No watchdog, automatic restore on exit, absent-display reconnect,
gamma change, private setter, logout or reboot is part of this command.

Mirroring may change modes, refresh or HDR; recovery verifies captured public
modes, arrangement and main display but does not restore HDR settings, color
profiles, rotation, window placement or Spaces. See [mirroring](display-mirroring.md)
for the full contract. Stop on unexplained mismatch rather than repeating toggles.

## Offline verification

`swift test --disable-sandbox --filter 'DisplayMirroringTests|DDCTests|CLIParserTests' -Xswiftc -warnings-as-errors`
uses fake channels, snapshots and configuration writers. Handoff cases cover
ordered success, omitted input, unavailable DDC, zero input, changed DDC target,
unverified selection, DDC failure on either command, hide/unhide failure,
journal creation failure and a back selector different from the saved target.
No hardware changes or DDC hardware queries are needed for these tests.

## Pending supervised round trip

AC4 remains pending. Fresh approval must name the S2721DGF target and explicit
surviving source, input codes (historically HDMI 1 / DP1), journal path, user
presence, and acceptable monitor-input-button / manual Displays-settings
fallback. Rediscover current identities; do not reuse historical numeric IDs.
Obtain fresh approval for each away/back write. Stop on the first unexplained
mismatch; fallback or retries require separate approval.

Record date, host/build, monitor/firmware/connection, fresh target/source UUIDs,
original modes/refresh/HDR, consent and journal before writes. Observe the other
computer's picture, disappearance of the separate Mac desktop, usable survivor,
source mode/HDR effects and cursor/Spaces behavior after away. After back,
record verified topology plus visible Mac output, arrangement/modes/main and any
window/Spaces changes. Non-DDC monitors remain manual-input and untested unless
separately approved and observed.
