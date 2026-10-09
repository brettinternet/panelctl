# Changelog

## 0.8.0

- Redesign the app icon and menu-bar mark.
- Preserve hidden displays across wake layout drift.
- Build and test releases with Xcode 26.6 on macOS 26 runners.

## 0.7.0

- Add a standalone Move windows action and opt-in Keep windows off for individual hides, with explicit Accessibility permission controls.
- Sign app and CLI releases with a stable self-signed identity so privacy grants can survive updates. The first upgrade from ad-hoc signing requires re-granting permissions.
- Improve Settings layout, window-moving controls, and copyable CLI commands.
- Fix Show recovery after monitor input return, Escape focus recovery, and Run now with verified hidden displays.
- Fix one-shot automation lifecycle and failure reporting, prevent combined full-display coverage, and handle larger status-stream frames.
- Add local development initialization, formatting and lint hooks, and signing settings in `.env`.

## 0.6.2

- Add `panelctl app status --watch` for live status integrations.
- Add `panelctl app run-rule` and per-rule Run now, Copy CLI command, and menu controls.
- Fix status-stream test hangs on constrained CI runners.

- Retire `panelctl app blackout-now` and the broadcast Blackout Now menu action. Use `panelctl app hide --display UUID` for one display, `run-action` for saved Hide/Show steps, or `run-rule` to run one Automation rule.
- Add `--style black-out` to `panelctl app hide` and `toggle-hide` to force a black cover without changing a display's configured Hide style or preferences. Styled requests use protocol 2 so older running apps safely refuse them; ordinary requests remain protocol 1.
