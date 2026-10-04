import AppKit
import PanelCtlCore

@MainActor
enum DisplayOperationConfirmation {
    static let recoveryAcknowledgement = "I have another usable display and can use the monitor buttons or macOS Displays settings if needed."

    static func hideMessage(
        _ request: DisplayHideRequest,
        journalPath: String
    ) -> String {
        let targetName = request.target.name ?? "Display \(request.target.id)"
        let sourceName = request.source.name ?? "Display \(request.source.id)"
        return """
        Experimental · mirror hide

        Target: \(targetName)
        \(request.target.identityDetail)

        Explicit mirror source: \(sourceName)
        \(request.source.identityDetail)

        Other computer input on Hide: \(inputDescription(request.awayInput, warning: request.awayInputWarning, purpose: "Other computer"))
        Mac input on Show: \(inputDescription(request.returnInput, warning: request.returnInputWarning, purpose: "Mac"))
        DDC may be unavailable or may not verify a switch. Manual monitor-button switching remains available; an unverified result will not be reported as changed.

        This hides the separate desktop by mirroring the source. The Mac signal remains on. Resolution, refresh rate, and HDR may change. Show restores the captured public layout and modes, not HDR, color profiles, rotation, windows, or Spaces.

        Recovery journal: \(journalPath)

        PanelCtl protection pauses while the journal is unresolved. External CLI watchers and other display apps do not honor PanelCtl's locks; stop them before proceeding.

        While hidden, PanelCtl cannot black out \(sourceName) or any other display. An OLED source stays lit until you Show or macOS display sleep turns it off.
        """
    }

    static func showMessage(_ request: DisplayShowRequest) -> String {
        showMessage(request.status, returnInput: request.returnInput, returnInputWarning: request.returnInputWarning)
    }

    static func showMessage(_ status: DisplayHandoffStatus, returnInput: UInt8? = nil,
                           returnInputWarning: String? = nil) -> String {
        let target = status.target
        let source = status.source
        let targetName = target?.name ?? "journaled display"
        let sourceName = source?.name ?? "captured mirror source"
        return """
        Experimental · mirror hide

        Journaled target: \(targetName)
        \(target?.identityDetail ?? "Target identity unavailable")

        Captured mirror source: \(sourceName)
        \(source?.identityDetail ?? "Source identity unavailable")

        Mac input on Show: \(inputDescription(returnInput, warning: returnInputWarning, purpose: "Mac"))
        Show restores the captured public display layout and modes, not HDR, color profiles, rotation, windows, or Spaces. Restoring the layout may affect other captured displays. If DDC is unavailable, fails, or is unverified, use the monitor's input buttons; input failure never blocks restoring the desktop.

        Recovery journal: \(status.journalPath)

        PanelCtl protection remains paused until the shared journal is verified resolved. After a successful Show, enabled protection starts with a fresh idle countdown.
        """
    }

    private static func inputDescription(_ value: UInt8?, warning: String?, purpose: String) -> String {
        if let warning { return "\(purpose) input not requested — \(warning)" }
        guard let value else { return "No \(purpose.lowercased()) input change requested; use monitor buttons if needed." }
        let code = String(format: "0x%02X", value)
        let name = DDCInput.namedValues.first(where: { $0.value == value })?.name
        return "\(name.map { "\($0) (\(code))" } ?? code)"
    }

    struct PreparedConfirmation {
        let alert: NSAlert
        let cancelButton: NSButton
        let actionButton: NSButton
        let acknowledgement: NSButton
        private let acknowledgementTarget: AcknowledgementTarget

        func runModal() -> NSApplication.ModalResponse {
            // Cancel is the default (Return) button, so give Escape an explicit
            // scoped route too. NSAlert otherwise assigns it to the second button.
            let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53, event.window === alert.window,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
                    return event
                }
                cancelButton.performClick(nil)
                return nil
            }
            defer { if let monitor { NSEvent.removeMonitor(monitor) } }
            return alert.runModal()
        }

        fileprivate init(alert: NSAlert, cancelButton: NSButton, actionButton: NSButton,
                         acknowledgement: NSButton, acknowledgementTarget: AcknowledgementTarget) {
            self.alert = alert
            self.cancelButton = cancelButton
            self.actionButton = actionButton
            self.acknowledgement = acknowledgement
            self.acknowledgementTarget = acknowledgementTarget
        }
    }

    static func prepareConfirmation(
        title: String,
        message: String,
        actionTitle: String
    ) -> PreparedConfirmation {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: actionTitle)

        let acknowledgement = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        acknowledgement.setAccessibilityLabel(recoveryAcknowledgement)
        let label = NSTextField(wrappingLabelWithString: recoveryAcknowledgement)
        label.setAccessibilityElement(true)
        label.setAccessibilityLabel(recoveryAcknowledgement)
        label.setAccessibilityRole(.staticText)

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 48))
        acknowledgement.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(acknowledgement)
        accessory.addSubview(label)
        NSLayoutConstraint.activate([
            acknowledgement.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            acknowledgement.topAnchor.constraint(equalTo: accessory.topAnchor, constant: 2),
            acknowledgement.widthAnchor.constraint(equalToConstant: 18),
            acknowledgement.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: acknowledgement.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            label.topAnchor.constraint(equalTo: accessory.topAnchor),
            label.bottomAnchor.constraint(equalTo: accessory.bottomAnchor)
        ])
        alert.accessoryView = accessory

        let actionButton = alert.buttons[1]
        // NSAlert may assign Escape to its second button. That is the write
        // action here, so only Cancel may own the cancellation shortcut.
        actionButton.keyEquivalent = ""
        actionButton.isEnabled = false
        let target = AcknowledgementTarget(actionButton: actionButton)
        acknowledgement.target = target
        acknowledgement.action = #selector(AcknowledgementTarget.changed(_:))

        let cancelButton = alert.buttons[0]
        alert.window.defaultButtonCell = cancelButton.cell as? NSButtonCell
        return PreparedConfirmation(
            alert: alert,
            cancelButton: cancelButton,
            actionButton: actionButton,
            acknowledgement: acknowledgement,
            acknowledgementTarget: target
        )
    }

    static func confirm(
        title: String,
        message: String,
        actionTitle: String
    ) -> Bool {
        let confirmation = prepareConfirmation(title: title, message: message, actionTitle: actionTitle)
        return confirmation.runModal() == .alertSecondButtonReturn && confirmation.acknowledgement.state == .on
    }
}

@MainActor
private final class AcknowledgementTarget: NSObject {
    private weak var actionButton: NSButton?

    init(actionButton: NSButton) {
        self.actionButton = actionButton
    }

    @objc func changed(_ sender: NSButton) {
        actionButton?.isEnabled = sender.state == .on
    }
}
