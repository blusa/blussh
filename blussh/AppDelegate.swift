import SwiftUI
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var sshService = SSHService()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
        }

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 350, height: 350)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: StatusMenuView(sshService: sshService))
        self.popover = popover

        self.sshService.checkServers()
        self.updateStatusIcon()

        let frequencies: [(label: String, value: TimeInterval)] = [
            ("5s", 5),
            ("10s", 10),
            ("1m", 60),
            ("5m", 300)
        ]
        let frequencyIndex = UserDefaults.standard.integer(forKey: "selectedFrequencyIndex", defaultValue: 1)
        let frequency = frequencies[frequencyIndex].value
        self.sshService.updateTimer(frequency: frequency)

        sshService.$globalStatus
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
        switch sshService.globalStatus {
            case .allOnline:
                color = .systemGreen
            case .someOnline:
                color = .systemOrange
            case .allOffline:
                color = .systemRed
            case .notInitialized:
                color = .systemGray
        }
        let title = NSMutableAttributedString(string: "BluSSH ")
        let dot = NSAttributedString(string: "●", attributes: [.foregroundColor: color])
        title.append(dot)

        statusItem.button?.attributedTitle = title
        statusItem.button?.image = nil
    }
}
