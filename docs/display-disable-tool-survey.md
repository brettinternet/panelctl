# Display disable: how other tools do it

How four macOS display tools implement per-monitor "disable", from their public
code, issue trackers and release notes. Tools are named by role. The resulting
design is [private display disable](display-disable.md).

## Mechanism

All four call `CGSConfigureDisplayEnabled(config, displayID, enabled)` inside a
`CGBeginDisplayConfiguration` / `CGCompleteDisplayConfiguration` transaction
(SkyLight exports it as `SLSConfigureDisplayEnabled`).

- Re-enable passes `true` with the ID saved before disabling.
- A disabled display leaves the layout and the public online list; windows
  move off it. Monitors usually lose signal and enter standby, but not all.

| Binding | If the symbol disappears |
| --- | --- |
| `dlsym` with fallback and an "unavailable" state | Feature disabled; app still works |
| Static import | App fails to launch |
| `@_silgen_name` with a Swift signature | Launch failure; works on arm64 by accident |

## Commit scope

| Scope | Behavior |
| --- | --- |
| App-only | After a force quit the display stayed disabled and unlisted until restart or another port |
| Session | Re-enabled on normal quit and signals; crash and SIGKILL can't |
| Permanent | May survive reboot; restart is still the documented recovery |

No scope reconnects a display when the process dies, so recovery must come
from another process and a saved journal. Use session scope.

## Fallbacks

| Method | Notes |
| --- | --- |
| Mirror + zero gamma | Gamma must be reapplied; a macOS bug can leave a screen blank |
| Mirror + brightness 0 | Needs something to keep reapplying it |
| Overlay | Safest; works on any display, but the monitor stays on and windows stay |
| DDC power | Monitor may not wake over DDC; user presses power |

## Patterns worth copying

- **Saved ID.** Every tool reconnects by the ID saved before disabling.
- **Intent vs observation.** Store disconnect intent separately; accept
  disconnects macOS made on its own; never guess between identical displays.
- **Sleep/wake.** Snapshot before sleep, restore after wake with a fixed
  attempt budget, and wait out transitions.
- **System reconnects.** macOS may reconnect displays on wake. Accept it.

## Guard rails

- Never leave zero usable displays; virtual displays don't count.
- Refuse built-in-only setups with the lid closed. Some Macs don't reconnect a
  disabled built-in until restart.
- Disable the feature while DisplayLink runs.
- Avoid Intel: soft disconnect may not fully sleep the display.
- Keep disabled displays listed and reconnectable.
- Don't guess sequential IDs for displays you didn't record.

## Failure reports

- A force quit left a display disabled and unlisted.
- Replugging into the same port didn't help; another port did, possibly with a
  new ID.
- Unplugging the last external display with the built-in disabled left a black
  screen.
- Last resorts everywhere: replug, close and open the lid, restart.
