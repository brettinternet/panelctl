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
  console session UUID plus audit ID and observed WindowServer PID **plus
  microsecond start time** (public `KERN_PROC_ALL`). Callback
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
  can mark bounded recording completion; it is published without replacement
  only after `summary.pending.json` is written, synchronized and closed. The
  pending file alone is never completion. Absent summary, partial JSONL, process
  death, or a failed terminal write must be interpreted as incomplete. A new
  invocation always creates a different collector UUID/directory; it cannot
  continue the old recording. Directory mode is 0700, file mode 0600.

Readiness means **recording armed, not recovery available**. The 60 seconds
start after readiness; setup/final collection add time. Native API calls cannot
be interrupted safely, and OS scheduling, sleep, process death or a hung driver
can defeat a timing target. A detected wall-clock/scheduling gap is incomplete.
Normal/error cleanup removes callbacks and releases IOKit handles and locks;
if CG callback removal fails, its closed bounded context is intentionally retained
until process exit to prevent use-after-free. Process exit also releases the
advisory lock. No watchdog launches or restores.

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

Compiler and 13 focused offline tests pass: private/no-overwrite recording,
receipt times, readiness/failure handling, record/queue/property bounds, required
console context, failed/successful callback removal, terminal sync/close failures,
service-read errors and pre-readiness queue overflow. A NaN fixture initially
exposed an Objective-C JSON exception; validating JSON before serialization
fixed it. Fresh independent review identified the latter four failure paths;
fixes and direct regression tests passed follow-up review (`6c2fb1d9`).

Preflight found no `kCGSSessionIDKey` and `proc_pidinfo` denied WindowServer with
EPERM. The observer now requires the actual console session UUID plus audit ID
and reads public `KERN_PROC_ALL` PID/start time, independently checked against
`ps`. Missing either remains blocking; no PID-only fallback. Dell identity,
origin `(3440,-4)`, OS/build/boot and five/four/zero service counts still match.
The existing operation lock was free; no recovery helper was running. Unrelated
blackout process remains untouched.

At `001846a`, full suite: 190 tests, 188 passed, two intentionally skipped
(live origin trial and optional retained ICC replay), zero failures. All trial
and ICC-replay variables were explicitly unset. Release builds of `panelctl`
and `observe-recovery-identity` passed. LSP returned unknown, not clean.
Test log: `/tmp/panelctl-observer-001846a-tests.log`. Synthetic test evidence is
retained in OS temporary `panelctl-observer-tests-*` directories.

## Single passive control — completed 2026-10-02

Ran the release executable at `001846a` once after preflight and review. No
physical action, state change, guard/restore, origin trial, or private enable
was performed. Recording completed with no reported failure:

- 60.011999125 seconds from readiness receipt to end receipt, 37 records,
  57,892 event-stream bytes, no application overflow or collector restart.
- Seven successful primary registrations (CG plus six IOKit iterators), nine
  successful general-interest registrations, six valid initial drains before
  readiness. Nine initial services: five shims and four proxies; no AppleCLCD2.
- **Zero subsequent publication/termination/general-interest or CG callbacks
  received.** This does not prove no events occurred or complete delivery.
- Two matching bounded inventories: public IDs `1,2,3,5`; private IDs
  `1,2,3,4,5`. Unknown offline ID 4 was not filtered or treated as a monitor.
  All nine retained service property/path/entry-ID records matched.
- Dell stayed ID 1, active/non-main/external at `(3440,-4)`, with the expected
  CG UUID, vendor/model/serial and shim entry `4294970171`. No origin correction.
- Boot/build/user, console UUID/audit ID and WindowServer lifetime matched at
  inventory boundaries. WindowServer PID 475, start `(1790881673,730621)`;
  boot `9D95EE40-D277-457A-8A81-A2BCBB7F1CF5`, build `26A434`.
- Fresh baseline and after snapshots were exactly equal, including raw ICC
  hashes. All four retained raw ICC files independently hashed to baseline.
- Independent JSON/sequence/bounds/permissions checks passed: directory 0700,
  all files 0600. CG removal returned success. Operation lock independently
  reacquired/released afterward; no helper/observer remained. Existing blackout
  PID 60480 was left untouched. No visible-output or window-placement claim.

Private artifacts:

- Recording, baseline, raw ICCs, after snapshot, and completion summary:
  `/var/folders/jp/1mwx72h172955139pth4h8800000gn/T/panelctl-identity-observation-72615DA4-A28B-40AE-99A4-E6655B86796D/`
- Preflight and independent artifact-validation record:
  `/var/folders/jp/1mwx72h172955139pth4h8800000gn/T/panelctl-observer-preflight.XmXuIgfdUy/`
- Preflight identity diagnostic:
  `/var/folders/jp/1mwx72h172955139pth4h8800000gn/T/panelctl-identity-inspection-06B410D2-206D-429C-B0E7-62516961D5AC/report.json`

**Disposition:** passive startup/recording/cleanup control passed. No disconnect
transition, physical monitor lifetime or logically-offline hardware-to-CG-ID
binding was tested. Private re-enable remains blocked. Stage B is not approved
and must not follow automatically. Retain the existing checkout and all old
journals unchanged; no push, PR or merge.
