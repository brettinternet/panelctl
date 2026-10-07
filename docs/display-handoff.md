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
back: validate journal and identities → [switch input → wait for modes/topology] → restore layout → verify
```

| Situation | Result |
| --- | --- |
| Journal can't be saved | Nothing changes |
| No DDC, or input reads as zero | Input skipped; Hide continues |
| Input can't be confirmed | Away continues; check the monitor |
| Input write fails | Away stops before mirroring |
| Mirroring fails after input switched | Prints switch-back and restore commands |
| Saved target mode unavailable on back | Try the configured Mac input once, then recheck; without `--input`, select it manually |
| Layout restore fails on back | Input may already have switched; precise blocker reported and unresolved journal retained |
| Input fails on back | Restore only if fresh mode/topology checks pass; report the input failure separately |

One input write, no retries, no automatic rollback. The switch-back command is
printed, not saved, so keep the output or use the monitor's input button.

Input return can reconnect a display or reinstate mirroring. Show/back waits up
to five seconds for two matching, identity-checked topology observations with
all saved modes available before restoring. A returned mirror is not a shown
desktop: the selected display is explicitly restored and verified afterward.
The final Show/back verifies the exact journaled arrangement and main display.

An online monitor can still show the other computer. Inspection and wake never
unmirror or switch inputs just because it is online. Only explicit Show/back
requests this return. Missing/changed identities, unavailable saved modes or
unsettled topology stop restoration without discarding the journal. The app's
Show Actions use the same guarded path even while recovery needs attention.

## Returning from an empty input

A monitor showing an input with no signal may go black or into standby and
stop answering DDC. `back` still tries the return input once. If the monitor
doesn't respond, select the Mac's input with its buttons.

## Tests

```sh
swift test --disable-sandbox --filter 'DisplayMirroringTests|DDCTests|CLIParserTests' -Xswiftc -warnings-as-errors
```
