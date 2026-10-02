# Origin-only qualification trial

Target approved in the interactive session: DELL S2721DGF, UUID
`09084682-3c42-4455-aab8-126a7431125b`, vendor/model/serial
4268/16857/1094800204. Baseline origin `(3440,-20)`; trial `(3440,-4)`.
Only a 16-point downward desktop-origin movement is permitted. Rotation, mode,
mirroring, main-display selection, color, power, and private APIs are untouched.

Safety review before the trial:

- The existing writer avoids unchanged mode/mirror writes, commits for session,
  validates identity twice, and journals restoration intent first.
- Missing displays still block. Optional absent connector/color metadata is not
  positive identity evidence; the trial requires a nonempty target connector.
- Snapshot collection is non-atomic. Repeat capture detects observed races but
  cannot exclude another utility changing topology after the last check.
- READY is not a lifetime guarantee. A separate origin writer could race the
  deadline and mutate after restoration. The test payload is therefore handled
  by the existing watchdog, serialized with its deadline/EOF callbacks.
- Before moving, the helper persists intent, checks the exact baseline again,
  stages only the origin, and commits for session. It verifies the expected
  intermediate topology. Unexpected results stop all writes with retained
  `needsAttention` evidence. Before timed restoration it again checks that only
  the expected origin changed. No write retries occur.
- The watchdog cannot recover from its own death or WindowServer/driver failure.
  Sleep can delay timers. Stay awake and keep other display utilities idle.
- Topology equality does **not** restore or verify application-window placement.

The live XCTest is skipped unless `PANELCTL_APPROVED_ORIGIN_TRIAL` is explicitly
`timed` or `parent-kill`, with `PANELCTL_TRIAL_BINARY` pointing to the freshly built
panelctl and `PANELCTL_TRIAL_JOURNAL` to a new private evidence directory. There
is no new CLI trial/disable command or startup behavior. Do not set these
variables without specific approval. The timeout is 10 seconds from capture.
The crash variant kills only the test parent itself after the helper records
and verifies the move; it must follow a successful timed trial and separate
approval. The external operator then checks the retained journal and runs
read-only `recovery verify`.

Fallback after any unexplained mismatch: stop, retain evidence, ask the user to
restore arrangement manually in System Settings → Displays from another working
screen. No automatic fallback writes, power commands, session termination,
preference deletion, or reboot. Ask for visible-output confirmation after each
successful trial before considering the next.

## Results

On 2026-10-02, after explicit interactive approval, **one session-scoped origin
write** moved the Dell to `(3440,-4)`. Intermediate verification immediately
failed: ICC-profile digests changed for main Dell AW3423DW and AW3425DW. All
captured topology/mode/identity fields otherwise matched the expected origin
move. No mode, rotation, mirror, color, power, or private setters were requested.
Whether these hashes reflect a real color change or regenerated profile data is
unexplained; checks were **not** weakened.

The helper stopped in `needsAttention`; no restoration write or parent-kill
trial followed. This is a **failed qualification**, not a successful timed
restore. The user confirmed all displays visibly working and authorized safe
work only, leaving manual arrangement correction to them. Exact baseline
restoration and application-window placement are not claimed.

Evidence retained:

- Original journal and read-only post-trial snapshot:
  `/var/folders/jp/1mwx72h172955139pth4h8800000gn/T/panelctl-origin-timed.znW5fTJGAI/`
  (`current.json`, `observed.json`, `final-observed.json`). Final read-only
  verification still refused the original snapshot; the last capture retained
  the same post-trial origin and ICC hashes.
- Test transcript: `/tmp/panelctl-origin-timed.log`.
- Original → observed ICC digests:
  - AW3423DW: `f1e8d8fa436fc90eccc6d94852e3de30f6e0f231009ebbe8e13fa5877dfa0fdd`
    → `8868d1405f18ca2d6b9ed406632b938277ceef5a4adfae49faee8877d887ec48`.
  - AW3425DW: `520d9467b35d628e21a5d56b4a11f19df67f75c3987c98f4ac51fa011fc7a17a`
    → `fa2e25f3df4effdbb9293fc38b688344086f3aa6a75a9debbd4ddf3c0f8c6c7d`.

Read-only subprocess rehearsal passed before the live trial with artifacts at
`/var/folders/jp/1mwx72h172955139pth4h8800000gn/T/panelctl-recovery-integration-78BA7240-0E15-445E-90FD-BCA08E822387`.
No test helper remained running after the trial. Another live trial requires
explaining the mismatch, fresh baseline/preflight, and new explicit approval.
