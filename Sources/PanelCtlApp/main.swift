import AppKit

let application = NSApplication.shared
let delegate = MainActor.assumeIsolated {
    AppDelegate { isPresented in
        application.setActivationPolicy(isPresented ? .regular : .accessory)
        if isPresented { application.activate(ignoringOtherApps: true) }
    }
}
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
