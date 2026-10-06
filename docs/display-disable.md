# Private display disable

Drop the Mac's signal to one monitor so a multi-input monitor can switch to
another computer, then reconnect it safely. Mirroring and DDC input switching
can't do this: the Mac's signal stays on.

> [!WARNING]
> This uses a private macOS API with no compatibility promise. Some monitors
> don't reconnect automatically; you may need to select the Mac's input with
> the monitor's buttons or replug the cable. Blackout is the safe alternative.

## Mechanism

```c
CGDisplayConfigRef config;
CGBeginDisplayConfiguration(&config);
CGSConfigureDisplayEnabled(config, displayID, false);   // true to reconnect
CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
```

- The setter is loaded at runtime (`CGSConfigureDisplayEnabled`, falling back
  to SkyLight's `SLSConfigureDisplayEnabled`) with the signature
  `@convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> CGError`.
  If macOS changes, the feature reports unavailable instead of breaking.
- **Session scope only.** App scope strands displays after a force quit;
  permanent scope survives reboot. No scope reconnects a display when the
  process dies, so a separate helper owns recovery.
- Reconnect uses the display ID saved before disconnecting. A disconnected
  display usually disappears from the online list, so it can't be looked up.
- No retries. Completion consumes the transaction even on error.

## CLI

```sh
panelctl recovery disable --display UUID --consent-disable --timeout 15s
panelctl recovery status
panelctl recovery enable
panelctl recovery panic
```

- `disable` takes one display, explicit consent and a 1–60 second timeout. No
  `--all` and no indefinite mode.
- The command stays attached until the timeout. Exit, Ctrl-C or a killed parent
  ends it early, and the helper reconnects the display.
- `enable` and `panic` reconnect only the display recorded in the journal, even
  if it's offline. `status` only reads.
- All take `--journal <path>`. Exit 0 on success, 1 on refusal or failure, 2
  on bad arguments.

## App controls

**Settings → Displays → Full disconnect · Experimental** appears for the
selected display while Experimental features are on (or while a disconnect is
unresolved).

1. Show any hidden displays and resolve any recovery first.
2. Choose **Disconnect…**. PanelCtl pauses automation and restores dimmed
   brightness.
3. Confirm you're present, a named display stays usable, and you accept manual
   recovery. Consent expires after 30 seconds and covers one 15-second
   disconnect.
4. The display reconnects at the deadline, or earlier with **Reconnect…**.
   Automation resumes once reconnection is verified.

Main and built-in displays are refused. **Reconnect…** stays available after
relaunch, with the display absent, and with Experimental features off.
Scripts, rules, startup and wake never disconnect a display.

## Safety checks

Every check reruns before each step. Any change cancels the operation.

| Required | Refused |
| --- | --- |
| Apple Silicon and a recognized macOS setter | Intel, unknown macOS builds |
| One external, physical, non-main target | Main, built-in, mirrored, virtual, headless |
| Another awake physical display stays usable | Only virtual, headless or DisplayLink displays left; closed lid |
| No mirroring | Any mirror |
| Only Apple display drivers | DisplayLink, virtual displays, third-party extensions |
| System, session and displays awake | Asleep or unknown |

Sleep, wake and display changes pause the operation; if it can't settle in 5
seconds, the journal is marked `needsAttention` instead of forcing a write.

### Identity

The display being reconnected must match the saved one exactly: vendor, model,
serial, connector, transport, boot session, OS build and user. Missing,
duplicate or changed evidence refuses. An offline display keeps its saved ID;
another ID is never substituted.

PanelCtl can't detect an identical monitor swapped onto the same port, or a
reused display ID.

## Journal

```text
disabling ─ setter OK ─→ staged ─ final check ─→ commitStarted ─ complete ─→ disabled
    └──────── any failure: cancel ─────────┘
```

Every recovery path (deadline, exit, signal, `enable`, `panic`, relaunch) runs
the same steps:

```text
lock → reload journal → check identity → one reconnect → up to 6 checks → verified | needsAttention
```

- An interrupted reconnect is never repeated.
- If macOS reconnects the display itself (for example on wake), PanelCtl
  accepts it and doesn't disconnect again.

## If it doesn't come back

1. `panelctl recovery status`, then `panelctl recovery enable`.
2. `panelctl recovery panic` (same checks, can't bypass a refusal).
3. Select the Mac's input with the monitor's buttons.
4. Log out or restart (not guaranteed to help).
5. Replug the cable, or try another port. A new port may give the display a
   new ID.

PanelCtl never escalates automatically. Windows, Spaces, HDR and color are not
restored.

## Tests

Tests use fake writers and never call the private setter:

```sh
swift test --disable-sandbox --filter 'Recovery'
swift test --disable-sandbox --filter RecoveryProductionProviderTests   # read-only checks on this Mac
```

Out of scope: DDC power as a fallback, link stop/start, permanent scope,
scanning for IDs, and automatic logout or reboot. See the
[tool survey](display-disable-tool-survey.md) for how other apps do this.
