# ICC mismatch investigation

## Read-only finding (2026-10-02)

The failed origin trial changed the full ICC SHA-256 values on AW3423DW and
AW3425DW, despite requesting only an origin change on DELL S2721DGF. Read-only
inspection now explains the mismatch: **only the profile creation timestamp
needs to change to reproduce both original hashes exactly**.

`scripts/inspect-recovery-color.swift [journal.json]` exports the current
`CGDisplayCopyColorSpace(...).copyICCData()` bytes, repeated-read comparison,
ColorSync device registration, and optional comparison against a journal. It
creates a new 0700 OS temporary directory with 0600 artifacts. It never changes
display configuration, profile selection, or the supplied journal.

Original read-only capture:
`/var/folders/jp/1mwx72h172955139pth4h8800000gn/T/panelctl-color-inspection-A9A2D3FF-A0AD-4393-8B10-E2AA9F636CB6/`.

| Display | Current bytes | Original creation time recovered from hash | Current creation time |
| --- | ---: | --- | --- |
| AW3423DW | 528 | 2026-10-02 08:52:52 | 2026-10-02 10:20:46 |
| AW3425DW | 516 | 2026-10-02 08:52:52 | 2026-10-02 10:20:46 |

The current ICC bytes exactly match their registered files in
`/Library/ColorSync/Profiles/Displays/`. ColorSync reports factory default
`HDMI HD` for both affected displays. No custom profile registration was
reported. Their profile-ID fields (bytes 84–99) are zero. Repeated reads are
byte-identical. DELL S2721DGF and K272HUL retain their original full ICC hashes.

## How the historical comparison was established

The old journal retained only hashes, not raw ICC bytes. The investigation did
**not** treat an absent byte-level baseline as proof of color equality. Instead,
for each affected current profile it tried candidate creation times over the
bounded interval 2026-09-25 through 2026-10-02, replacing only bytes 24–35. The
candidate at 2026-10-02 08:52:52 reproduces the saved full SHA-256:

- AW3423DW: `f1e8d8fa436fc90eccc6d94852e3de30f6e0f231009ebbe8e13fa5877dfa0fdd`
- AW3425DW: `520d9467b35d628e21a5d56b4a11f19df67f75c3987c98f4ac51fa011fc7a17a`

Precisely, with `current` the exported bytes:

```python
candidate = current[:24] + struct.pack(">6H", 2026, 10, 2, 8, 52, 52) + current[36:]
assert hashlib.sha256(candidate).hexdigest() == original_journal_hash
```

This provides cryptographic evidence that all other bytes, including the entire
tag table and color-transform payload, are unchanged. It does not reconstruct
an independently captured old file, prove actual emitted color, or rule out
other uncaptured HDR/VRR/window state changes. No profile data was installed or
written back to ColorSync, and no recovery journal was edited.

[ICC.1:2004-10 §7.2.8](https://www.color.org/ICC1V42.pdf) defines bytes 24–35
as the profile's first-creation date/time. This is separate from its color
transform data. The creation time equals the failed trial's local timestamp;
regeneration during reconfiguration explains the observed hash mismatch. We
do not claim knowledge of the private macOS regeneration implementation.

## Recovery boundary

The old journal remains unresolved and must not be silently reinterpreted.
At the read-only observation, the Dell remains at `(3440,-4)`, not its original
`(3440,-20)`. The user previously confirmed all four displays visibly working.
No additional display writes have occurred during this investigation.

A narrowly scoped timestamp-independent fingerprint for **new** snapshots can
avoid this false positive, while retaining the raw hash for evidence and still
checking every other byte. Unsupported/malformed profiles and legacy snapshots
must retain strict full-hash comparison. A fix needs synthetic regression tests
and a new specifically approved live trial; this investigation alone does not
qualify restoration or private reconnection.
