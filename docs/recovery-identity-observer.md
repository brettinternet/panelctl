# Bounded read-only identity observer

`swift run observe-recovery-identity --passive-control` explicitly starts one
60-second passive DELL S2721DGF recording. **Do not disconnect anything.** No
other arguments, resume mode, recovery helper, display writer, or automatic
startup behavior exist. Production private re-enable remains blocked.

The executable uses the existing per-user recovery operation lock and creates a
new private temporary directory. It never reads or replaces an old journal.
`baseline.json` is a fresh, verify-only, captured recovery journal; it stays
captured, not armed/restored. Raw ICC files and `after-snapshot.json` are separate
evidence. The Dell must freshly match UUID/vendor/model/serial, active external
non-main state, and `(3440,-4)`; mismatch stops rather than correcting anything.
Other display utilities do not honor this lock and are not stopped.

## Recording contract

- Public IOKit publication and termination notifications for framebuffer shims,
  DCPAVServiceProxy and AppleCLCD2; general-interest registration on published
  objects; public CG reconfiguration callbacks. No device user client or rescan.
- All six initial matching iterators must drain to zero while valid before the
  readiness record is synchronized. Initial services are labeled separately
  from subsequent callbacks. General-interest message arguments are not read:
  there is no generic public payload size/lifetime contract.
- Every event has wall-clock and monotonic receipt time, sequence and collector
  UUID. Iterator-batch times are callback receipt times, not individual kernel
  occurrence times. Delivery/receipt order is not guaranteed causal order.
- Before-ready, event-triggered and after inventories include public/private
  enumerations, selected registry properties, paths/entry IDs, boot/build/user,
  console session ID and observed WindowServer PID **plus start time**. Callback
  IDs are recorded but never looked up. Only freshly enumerated IDs are queried.
- Retained service handles are reread at inventory boundaries, including proxies
  not directly reached through CG metadata. Same-object comparisons only avoid
  duplicate interest registrations; they never authorize a recovery operation.
- Hard application bounds: 128 CG IDs, 32 objects per iterator drain, 96 retained
  services, 256 pending CG callbacks, eight event-triggered inventories, 512
  event records, 64 KiB per record, 4 MiB event stream, 1 MiB per raw ICC and
  8 MiB raw ICC total. Selected property depth/collection/string/data sizes are
  bounded. Native APIs can allocate their returned values before our checks.
- Registrations and iterator validity are recorded. Overflow, invalid iterator,
  registration failure, missing/changed context, inventory mismatch or I/O error
  stops the run as incomplete. No reset, rescan, restart or retry is attempted.
- `started.json` explicitly marks a fresh incomplete run. Only `summary.json`
  can mark bounded recording completion; absent summary, partial JSONL, process
  death, or a failed terminal write must be interpreted as incomplete. A new
  invocation always creates a different collector UUID/directory; it cannot
  continue the old recording. Directory mode is 0700, file mode 0600.

Readiness means **recording armed, not recovery available**. The 60 seconds
start after readiness; setup/final collection add time. Native API calls cannot
be interrupted safely, and OS scheduling, sleep, process death or a hung driver
can defeat a timing target. A detected wall-clock/scheduling gap is incomplete.
Normal/error cleanup removes callbacks and releases IOKit handles and locks;
process exit also releases the advisory lock. No watchdog launches or restores.

## Interpretation limits

These are non-atomic, selected driver-published properties, potentially cached.
Missing properties are explicit nulls, not negative proof of physical presence.
Service/object lifetime is not monitor lifetime. A PID/start-time observation
is context evidence, not proof of continuous WindowServer event coverage.
Context is sampled at inventory boundaries, not continuously. OS event queues
are outside our bounds; no overflow signal or absent callback proves they lost
nothing. The final collection/unregistration boundary cannot provide an atomic
snapshot of both IOKit and WindowServer.

No physical or logically-offline transition is qualified. Unknown extra ID 4
is retained, not filtered. No journal gains enable authorization. Future manual
unplug/replug remains a separately approved negative control, not a means to
qualify physically attached but logically offline identity.

## Validation checkpoint

Initial implementation: compiler passed; seven focused offline tests passed
(recording/permissions/no overwrite, receipt times, readiness/failure handling,
record and queue bounds, property bounds). The NaN fixture initially exposed an
Objective-C JSON exception; validating JSON before serialization fixed it.
LSP returned unknown; it is not validation evidence. Independent review, full
suite and the single passive control are pending. No observation or display
state change has yet been run with this implementation.
