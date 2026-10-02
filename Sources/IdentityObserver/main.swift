import Foundation
import PanelCtlCore

// Deliberately no restore/guard/enable mode, old-journal input, or resume mode.
guard CommandLine.arguments == [CommandLine.arguments[0], "--passive-control"] else {
    fputs("usage: observe-recovery-identity --passive-control (60 seconds, read-only; do not disconnect)\n", stderr)
    exit(2)
}
do { try IdentityObservation.run() }
catch { fputs("Identity observation incomplete: \(error)\n", stderr); exit(1) }
