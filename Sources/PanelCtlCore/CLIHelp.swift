public enum CLIHelp {
    /// Release version displayed by `panelctl --version`.
    public static let version = "panelctl 0.3.5"

    public static func text(for command: String? = nil) -> String {
        switch command {
        case nil:
            return """
            Usage: panelctl <command> [options]

            Commands:
              list             List connected displays
              probe            Probe display capabilities
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
        case "blackout":
            return """
            Usage: panelctl blackout (--display <selector> | --index <n> ... | --all) [options]

            Select one or more displays with --display/--index, or use --all.
            --idle-after <duration> waits for inactivity before showing blackout.
            --timeout <duration> restores after the duration; --sleep-after <duration>
            restores then sleeps all displays. These limits are mutually exclusive;
            --all requires one. --watch keeps watching for future idle periods and
            requires --idle-after; explicit watch targets must expose a stable
            display UUID. --caffeinate prevents idle system sleep.

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
