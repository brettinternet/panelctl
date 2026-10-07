# Changelog

## 0.6.2

- Add `panelctl app status --watch` for live status integrations.
- Add `panelctl app run-rule` and per-rule Run now, Copy CLI command, and menu controls.
- Fix status-stream test hangs on constrained CI runners.

- Retire `panelctl app blackout-now` and the broadcast Blackout Now menu action. Use `panelctl app hide --display UUID` for one display, `run-action` for saved Hide/Show steps, or `run-rule` to run one Automation rule.
- Add `--style black-out` to `panelctl app hide` and `toggle-hide` to force a black cover without changing a display's configured Hide style or preferences. Styled requests use protocol 2 so older running apps safely refuse them; ordinary requests remain protocol 1.
