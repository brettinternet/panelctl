public enum CLIHelp {
    /// Release version displayed by `panelctl --version`.
    public static let version = "panelctl 0.8.1"

    public static func text(for command: String? = nil) -> String {
        switch command {
        case nil:
            return """
            Usage: panelctl <command> [options]

            Commands:
              list             List connected displays
              probe            Probe display capabilities
              recovery         Experimental disable and journal-driven recovery
              mirror           Journal and mirror an external target onto a source
              unmirror         Restore and verify the journaled topology
              away             Optionally switch input, then hide a display by mirroring
              back             Unhide the journaled display, then optionally switch input
              blackout         Black out selected displays
              ddc-luminance    Read or set luminance
              ddc-input        Read or switch the monitor input
              ddc-power        Experimental monitor power (manual recovery may be required)
              sleep-displays   Sleep every display
              wake-displays    Wake every display
              app              Control the PanelCtl app

            Options:
              -h, --help        Show help
              --version         Show version

            Use `panelctl help <command>` for command options. Durations are
            positive seconds, optionally with one suffix: s, m, or h.
            """
        case "list":
            return "Usage: panelctl list [--json]\nList connected displays."
        case "probe":
            return "Usage: panelctl probe [--json]\nProbe display capabilities, including DDC Get VCP input/luminance reads.\nA successful read is not write qualification; no monitor values are set."
        case "recovery":
            return """
            Usage: panelctl recovery <capture|status|verify|restore|enable|panic|rehearse|guard> [--journal <path>]
            Usage: panelctl recovery <verify|restore> [--display <UUID>] [--journal <path>]
            Usage: panelctl recovery disable (--display <selector> | --index <n>) --consent-disable --timeout <1s...60s> [--journal <path>]
            Usage: panelctl recovery <rehearse|guard> [--timeout <1s...60s>] [--journal <path>]

            capture journals the current display identities, modes, rotation, origins,
            mirroring, main display, and available color-space/ICC profile identity. status prints
            every removal in a public-mirror session. For several unresolved entries,
            verify and restore require --display <UUID>; one unambiguous entry may omit it.
            Verify is read-only and never Shows;
            restore Shows only the selected target and leaves siblings removed. The final
            Show restores public modes, origins, mirroring and the original main display for the same online
            displays, then verifies. If a main-target restore mismatches, keep the journal;
            turn off mirroring and drag the menu bar back in System Settings → Displays.
            Missing/ambiguous displays or changed rotation/color space require manual
            intervention. HDR/profile restoration is NOT implemented.

            Experimental disable requests one non-main external display for a bounded
            helper-owned lease. Consent is mandatory; there is no indefinite mode.
            Selectors use the same UUID, decimal/hex ID or index:<n> as blackout.
            A qualified physical survivor, identity, awake state and API are required.
            Production physical-sink identity is currently unqualified: disable refuses
            without a display write. Consent does not bypass this gate.
            enable and panic recover only the staged disabled-by-us journal target,
            even when offline; neither uses online selection or guesses another ID.
            Both preserve identity refusals and one-shot recovery evidence. panic never
            runs a global reset. CGRestorePermanentDisplayConfiguration, logout,
            reboot and replug are unverified fallbacks, not automatic recovery.
            Before a new disable, stranded intent is recovered (or refused); a new
            explicit selection is then required. Status is journal-only/no-write.
            Signal removal, monitor standby and input switching are different outcomes;
            none is hardware-qualified. Blackout remains the overlay alternative.

            rehearse starts an independent, no-write verification helper (default 5s).
            guard instead arms public-configuration restoration on deadline or parent
            exit. Neither can reconnect a missing display or qualify a private experiment.
            Failed or unresolved journals are retained and block subsequent captures.
            Resolved journals are archived on the next capture. Output includes JSON.
            The default journal is ~/Library/Application Support/PanelCtl/Recovery/current.json.
            A custom journal's parent directory must be private (mode 0700) and owned by you.
            No recovery tool can guarantee recovery from driver/WindowServer failure,
            logout, reboot, or termination of the helper. See docs/display-recovery.md.
            """
        case "mirror", "unmirror":
            return """
            Usage: panelctl mirror --display <selector> --source <selector> --consent-mirror [--journal <path>]
            Usage: panelctl unmirror [--display <selector>] --consent-unmirror [--journal <path>]

            Experimental public, session-scoped mirroring.
            Both selectors are explicit UUIDs, decimal/hex IDs or index:<n> from list.
            Refuses built-in targets, inactive/asleep displays, existing mirrors,
            ambiguous identities and recovery needing attention. A healthy public-mirror
            session may accept additional targets. Show only one with `unmirror --display`;
            multiple removals require an explicit selector. A main external target is
            accepted; macOS may keep it main, move main to the source or report another
            display as main. Captures topology before writes.
            Mirroring removes a separate desktop, NOT the signal; modes/HDR/refresh,
            windows and Spaces may change. No gamma, DDC or private display setters.
            unmirror --display restores only that target; while others stay removed macOS
            may place it near, not at, its saved origin. The final Show restores and
            verifies the immutable pre-first-Hide modes, origins, mirroring and main display.
            It does not restore window/Spaces placement or HDR settings. Failures keep every
            entry. Explicit fallback: panelctl recovery restore --display <UUID>
            [--journal <path>]; changed identity/rotation/color requires manual action.
            No automatic restore on exit, watchdog, or promise of crash recovery.
            Consent flags acknowledge risk; they do not make untested hardware safe.
            Uses the recovery default journal unless --journal is supplied. See
            docs/display-mirroring.md.
            """
        case "away", "back":
            return """
            Usage: panelctl away --display <selector> --source <selector> --consent-away [--input <code>] [--journal <path>]
            Usage: panelctl back --display <selector> --consent-back [--input <code>] [--journal <path>]

            away captures a durable mirror journal, optionally selects the monitor input,
            then hides its separate desktop by public session-scoped mirroring.
            back requires the selected target, Shows only that entry and verifies the
            topology FIRST, then optionally selects that target's input. Other removals
            remain hidden; the final back verifies the original session baseline. No DDC failure blocks unhide.
            --input accepts dp1, dp2, hdmi1, hdmi2, decimal 1..255 or hex 0x01..0xFF.
            DDC is attempted only with --input and a successful pre-read. Otherwise use
            the monitor's input button. Mirroring keeps the Mac signal on: no automatic
            input switching is promised for monitors without DDC. No private disable.
            Target/source restrictions and mode/HDR/window/Spaces limitations match mirror.
            Defaults to the shared recovery journal; use the same --journal for back.
            Errors retain evidence and print recovery commands; no automatic rollback,
            retry, watchdog or disruptive fallback. Stop on unexpected behavior.
            away can add a target beside healthy removals; status lists every target.
            See docs/display-handoff.md.
            """
        case "blackout":
            return """
            Usage: panelctl blackout (--display <selector> | --index <n> ... | --all) [options]

            Select one or more displays with --display/--index, or use --all.
            --mode <blocking|working> selects an opaque, input-blocking blackout or
            click-through working dimming that leaves focus and the pointer unchanged.
            --overlay-opacity <1...100> sets overlay darkness; --no-overlay disables
            composited darkening. Values below 100 and --no-overlay require working
            mode, and those two overlay options cannot be combined. --dim-to <0...100>
            experimentally lowers each supported external display to that percentage
            of its DDC luminance maximum, never raises brightness, and restores the
            captured value before dimming ends or sleep. DDC support is best-effort.
            --idle-after <duration> waits for inactivity before showing blackout.
            --timeout <duration> restores after the duration; --sleep-after <duration>
            restores then sleeps all displays. These limits are mutually exclusive;
            --all requires one. --watch keeps watching for future idle periods and
            requires --idle-after; explicit watch targets must expose a stable
            display UUID. --blackout-empty-displays additionally treats each selected
            display after it has no app windows and no pointer for one second.
            --keep-blackout-on-input keeps a partial blocking blackout installed during
            activity and restarts its Restore or Sleep timer; it cannot be combined
            with --dim-to. Working dimming always applies the same timer extension to
            partial selections, including hardware brightness. Full coverage always
            retains its fixed finite endpoint. Restore working dimming from the status
            menu or `panelctl app restore`. --caffeinate prevents idle system sleep
            (advanced). --keep-displays-awake keeps displays awake until --sleep-after
            while the screen is unlocked; macOS may sleep the Mac sooner, and the assertion applies globally.
            Hardware dimming applies to inactivity treatment, not empty-display-only blackouts.
            By default, automatic treatment defers while
            another app keeps the display awake; --ignore-playback disables that
            system-wide detection. --defer-camera additionally defers while any camera
            is in use without accessing its video.

            Selectors accept a display UUID or decimal/hex CG display ID. Use
            --index <n> or index:<n> for the one-based index from `panelctl list`.
            """
        case "ddc-luminance":
            return "Usage: panelctl ddc-luminance --display <selector> [--set <0..65535>] [--json]\nRead luminance, or set and verify it."
        case "ddc-power":
            return """
            Usage: panelctl ddc-power --display <selector> [--set <on|off>] [--accept-power-risk] [--json]
            Experimental DDC VCP 0xD6. No --set: read reported power state.
            on = MCCS DPM/DPMS On (0x01); off = DPM/DPMS Off (0x04).
            No standby, suspend, power-button-off (0x05), raw values or value cycling.
            --set off requires --accept-power-risk, acknowledging:
            \(DDCPower.risk)
            Requires an unambiguous active external display and readable DDC power state.
            At most one Set VCP, then one readback after 250 ms; no retry or restoration.
            Outcomes: reported, alreadyReported (no write), matchingReadback, unverified
            (readback transport lost). Delivery/readback is not proof of visible state.
            \(DDCPower.manualRecovery)
            No topology removal, input switching, automatic wake or app integration.
            No hardware is power-qualified. Use only while present, with accessible
            monitor power and another usable display. Exit 0 reports an outcome, not
            visible success; refusal/error exits 1, invalid arguments exit 2.
            """
        case "ddc-input":
            return """
            Usage: panelctl ddc-input --display <selector> [--set <dp1|dp2|hdmi1|hdmi2|1..255>] [--json]
            Read the monitor's input source (DDC VCP 0x60), or switch it. --set reads the
            current input first, writes once, then checks by reading. If the monitor stops
            answering after leaving this Mac's input, the result is unverified. Codes vary
            by monitor: read the current value on a known input first. This switches the
            monitor's input only; macOS still treats the display as attached. The monitor's
            input button is the fallback.
            """
        case "sleep-displays":
            return "Usage: panelctl sleep-displays [--keep-system-awake [--timeout <duration>]]\nSleep every display; --timeout requires --keep-system-awake."
        case "wake-displays":
            return "Usage: panelctl wake-displays\nWake every display."
        case "app":
            return """
            Usage: panelctl app <command> [options]

            Commands:
              enable, disable, toggle, status
              status --watch --json
              restore
              sleep-now
              snooze --for <duration>
              resume
              open-settings
              hide --display <UUID> [--style black-out]
              show --display <UUID>
              toggle-hide --display <UUID> [--style black-out]
              run-action --action <UUID>
              run-rule --rule <UUID>

            Control PanelCtl.app; status does not launch the app. --json emits
            the machine-readable response. status --watch --json streams complete
            line-delimited snapshots until disconnection, then exits non-zero.
            It never launches or reconnects to the app.
            snooze temporarily pauses automation
            for up to 30 days; resume ends a snooze early.
            hide, show and toggle-hide act like the display's Hide or Show in
            the running app and wait for the result. Hide uses the configured
            style by default; --style black-out forces a black cover for that
            Hide without changing preferences. --style is accepted only by
            hide and toggle-hide. Copy the default command from Settings > Displays.
            A display already in the requested state is a no-op.
            \(AppControlCommand.blackoutNowMigrationGuidance)
            `restore` ends Automation blackouts only; Show ends a manual Hide.
            run-action --action <UUID> invokes one saved Action with 1–8 ordered
            Hide (black out), Hide (remove from desktop), Show or Move windows steps,
            only in the running app. Accessibility is checked without prompting; use
            the in-app Allow Accessibility button before Move windows. It never launches,
            queues or retries a request.
            The workflow is preflighted as a whole, then runs sequentially and
            non-atomically. Disconnected or verified already-hidden targets can be
            skipped with a reason; identity and recovery safeguards still apply.
            Other problems stop the run and keep earlier changes. If no steps need
            changes, the result is no-op; skipped steps have outcome skipped.
            While it runs, competing display commands, other Actions, recovery
            cleanup, disconnect and quit are busy until completion.
            JSON returns one result per step, including privacy-safe Move windows
            counts and reason codes; text prints one line per step. Status reports the
            current/last Action result. A response-lost result
            does not cancel the run; inspect `panelctl app status --json` before
            deciding what to do. Do not assume atomic success or retry blindly.
            Actions run only when you choose Run or run their command; startup,
            login, wake, reconnection and Automation never run them.
            run-rule --rule <UUID> immediately runs exactly one saved Automation
            rule in the running app, bypassing its idle wait. It runs one cycle
            with that rule’s selection, dimming/blackout, input behavior and
            configured Restore or Sleep follow-up, then ends without re-arming.
            As a manual run, playback and camera automatic deferrals do not delay it.
            It works while that rule, Automation or Automation’s snooze is off
            and never changes saved settings. Find UUIDs with `app status --json`
            in `rules[].id`. Missing or malformed UUIDs are usage errors; a running
            selected rule or competing display operation returns busy. An unknown
            UUID or overlapping rule is refused; Full disconnect and unresolved
            recovery need recovery before the run can proceed.
            It never launches the app, queues or retries. A lost response does
            not cancel the run; check `app status --json` before deciding what
            to do. This is different from `run-action`, which executes ordered
            display Hide/Show/Move windows steps, and from app Hide, which keeps a display
            hidden until Show.
            Status includes `runningRule` with the stable UUID while it runs.
            Exit codes: 0 done or no-op, 1 refused, busy, failed or control
            failure, 2 usage, 3 app unavailable, 5 partial input outcome,
            6 recovery needed. Status includes each display and its input outcome.
            """
        default:
            return text(for: nil)
        }
    }
}
