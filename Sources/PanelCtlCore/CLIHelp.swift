public enum CLIHelp {
    /// Release version displayed by `panelctl --version`.
    public static let version = "panelctl 0.3.26"

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
            Usage: panelctl recovery disable (--display <selector> | --index <n>) --consent-disable --timeout <1s...60s> [--journal <path>]
            Usage: panelctl recovery <rehearse|guard> [--timeout <1s...60s>] [--journal <path>]

            capture journals the current display identities, modes, rotation, origins,
            mirroring, main display, and available color-space/ICC profile identity. status prints the journal;
            verify compares without display writes. restore explicitly restores public
            modes, origins, and mirroring for the same online displays, then verifies.
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
            Usage: panelctl unmirror --consent-unmirror [--journal <path>]

            Experimental public, session-scoped mirroring; not hardware-qualified.
            Both selectors are explicit UUIDs, decimal/hex IDs or index:<n> from list.
            Refuses main/built-in targets, inactive/asleep displays, existing mirrors,
            ambiguous identities and unresolved journals. Captures topology before writes.
            Mirroring removes a separate desktop, NOT the signal; modes/HDR/refresh,
            windows and Spaces may change. No gamma, DDC or private display setters.
            unmirror restores captured modes, origins, mirroring and main display,
            then verifies; it does not restore window/Spaces placement or HDR settings.
            Failures keep the journal. Explicit fallback: panelctl recovery restore
            [--journal <path>]; changed identity/rotation/color requires manual action.
            No automatic restore on exit, watchdog, or promise of crash recovery.
            Each real mirror/unmirror requires fresh scoped human approval. Consent
            flags acknowledge writes; tests and prior trials do not supply approval.
            Uses the recovery default journal unless --journal is supplied. See
            docs/display-mirroring.md for restrictions and the pending trial protocol.
            """
        case "away", "back":
            return """
            Usage: panelctl away --display <selector> --source <selector> --consent-away [--input <code>] [--journal <path>]
            Usage: panelctl back --display <selector> --consent-back [--input <code>] [--journal <path>]

            away captures a durable mirror journal, optionally selects the monitor input,
            then hides its separate desktop by public session-scoped mirroring.
            back requires the same journal target, restores and verifies the captured
            topology FIRST, then optionally selects the input. No DDC failure blocks unhide.
            --input accepts dp1, dp2, hdmi1, hdmi2, decimal 1..255 or hex 0x01..0xFF.
            DDC is attempted only with --input and a successful pre-read. Otherwise use
            the monitor's input button. Mirroring keeps the Mac signal on: no automatic
            input switching is promised for monitors without DDC. No private disable.
            Target/source restrictions and mode/HDR/window/Spaces limitations match mirror.
            Defaults to the shared recovery journal; use the same --journal for back.
            Errors retain evidence and print recovery commands; no automatic rollback,
            retry, watchdog or disruptive fallback. Stop on unexpected behavior.
            Each hardware handoff requires fresh scoped approval. Consent flags do not
            replace approval. Only the documented S2721DGF round trip is hardware-qualified.
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
            Hardware dimming applies to inactivity and Blackout Now cycles, not empty-display-only blackouts.
            By default, automatic treatment defers while
            another app keeps the display awake; --ignore-playback disables that
            system-wide detection. --defer-camera additionally defers while any camera
            is in use without accessing its video. Manual blackout-now commands are
            never deferred.

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
              blackout-now, restore
              sleep-now
              snooze --for <duration>
              resume
              open-settings
              hide --display <UUID>
              show --display <UUID>
              toggle-hide --display <UUID>

            Control PanelCtl.app; status does not launch the app. --json emits
            the machine-readable response. snooze temporarily pauses automation
            for up to 30 days; resume ends a snooze early.
            hide, show and toggle-hide act like the display's Hide or Show in
            the running app, using its Hide style, and wait for the result. Copy
            the command from Settings > Displays. A display already in the
            requested state is a no-op.
            Exit codes: 0 done or no-op, 1 refused, busy, failed or control
            failure, 2 usage, 3 app unavailable, 5 partial input outcome,
            6 recovery needed. Status includes each display and its input outcome.
            """
        default:
            return text(for: nil)
        }
    }
}
