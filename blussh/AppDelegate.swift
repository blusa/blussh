import SwiftUI
import Combine
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var engine = MonitoringEngine()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Replacing the bundle in /Applications silently invalidates the BTM login item;
        // re-register whenever the user wants launch-at-login but the system lost it.
        if UserDefaults.standard.bool(forKey: "launchAtLoginDesired"),
           SMAppService.mainApp.status != .enabled {
            do {
                try SMAppService.mainApp.register()
                NSLog("blussh: re-registered launch at login (status was lost)")
            } catch {
                NSLog("blussh: launch-at-login re-registration failed: \(error.localizedDescription)")
            }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
        }

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 350, height: 350)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: StatusMenuView(engine: engine))
        self.popover = popover

        engine.start()
        updateStatusIcon()

        let frequencies: [(label: String, value: TimeInterval)] = [
            ("5s", 5),
            ("10s", 10),
            ("1m", 60),
            ("5m", 300)
        ]
        let frequencyIndex = UserDefaults.standard.integer(forKey: "selectedFrequencyIndex", defaultValue: 1)
        engine.updateTimer(frequency: frequencies[frequencyIndex].value)

        engine.$globalStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusIcon()
            }
            .store(in: &cancellables)
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        if let button = statusItem.button {
            if popover.isShown {
                popover.performClose(sender)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }

    func updateStatusIcon() {
        let color: NSColor
        switch engine.globalStatus {
            case .allOnline:
                color = .systemGreen
            case .someOnline:
                color = .systemOrange
            case .allOffline:
                color = .systemRed
            case .notInitialized:
                color = .systemGray
        }

        let hostname = ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
            .uppercased()

        let font = NSFont(name: "Monaco", size: 13) ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let title = NSMutableAttributedString(
            string: "\(hostname) ",
            attributes: [.font: font]
        )
        let dot = NSAttributedString(string: "●", attributes: [.foregroundColor: color, .font: font])
        title.append(dot)

        let icon = NSImage(systemSymbolName: "pc", accessibilityDescription: "Computer")
        icon?.isTemplate = true

        statusItem.button?.image = icon
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.attributedTitle = title
    }
}
