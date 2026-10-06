# Away / back handoff

Hand a monitor to another computer: `away` [mirrors](display-mirroring.md) the
display so its desktop disappears and optionally switches its input. `back`
restores it and optionally switches back.

```sh
panelctl away --display TARGET_UUID --source SOURCE_UUID --input hdmi1 --consent-away
panelctl back --display TARGET_UUID --input dp1 --consent-back
```

- Targets and sources follow the [mirroring rules](display-mirroring.md).
- `--input` takes [ddc-input](ddc-input.md) names or codes. Omit it to send no
  DDC commands; the monitor won't switch on its own because the Mac's signal
  stays on.
- Use the same `--journal` for both commands.
- `back` shows only the selected target. The last `back` restores the original
  layout exactly.

The app's **Remove from desktop** Hide and Show use this same path.

## Order

```text
away: save layout → [read input → switch input] → mirror → verify
back: restore layout → verify → [switch input]
```

| Situation | Result |
| --- | --- |
| Journal can't be saved | Nothing changes |
| No DDC, or input reads as zero | Input skipped; Hide continues |
| Input can't be confirmed | Away continues; check the monitor |
| Input write fails | Away stops before mirroring |
| Mirroring fails after input switched | Prints switch-back and restore commands |
| Layout restore fails on back | No input write; restore command printed |
| Input fails on back | Desktop restored; switch-back command printed |

One input write, no retries, no automatic rollback. The switch-back command is
printed, not saved, so keep the output or use the monitor's input button.

## Returning from an empty input

A monitor showing an input with no signal may go black or into standby and
stop answering DDC. `back` still tries the return input once. If the monitor
doesn't respond, select the Mac's input with its buttons.

## Tests

```sh
swift test --disable-sandbox --filter 'DisplayMirroringTests|DDCTests|CLIParserTests' -Xswiftc -warnings-as-errors
```
