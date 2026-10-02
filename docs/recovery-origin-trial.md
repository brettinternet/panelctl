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

Pending first approved timed trial. Read-only subprocess rehearsal passed with
artifacts at `/var/folders/jp/1mwx72h172955139pth4h8800000gn/T/panelctl-recovery-integration-78BA7240-0E15-445E-90FD-BCA08E822387`.
