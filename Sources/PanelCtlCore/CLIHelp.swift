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
              recovery         Capture, verify, or restore display configuration
              blackout         Black out selected displays
              ddc-luminance    Read or set luminance
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
            return "Usage: panelctl probe [--json]\nProbe display capabilities."
        case "recovery":
            return """
            Usage: panelctl recovery <capture|status|verify|restore|rehearse|guard> [--journal <path>]
            Usage: panelctl recovery <rehearse|guard> [--timeout <1s...60s>] [--journal <path>]

            capture journals the current display identities, modes, rotation, origins,
            mirroring, main display, and available color-space/ICC profile identity. status prints the journal;
            verify compares without display writes. restore explicitly restores public
            modes, origins, and mirroring for the same online displays, then verifies.
            Missing/ambiguous displays or changed rotation/color space require manual
            intervention. Private reconnection and HDR/profile restoration are NOT implemented.

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

            Control PanelCtl.app; status does not launch the app. --json emits
            the machine-readable response. snooze temporarily pauses automation
            for up to 30 days; resume ends a snooze early.
            """
        default:
            return text(for: nil)
        }
    }
}
