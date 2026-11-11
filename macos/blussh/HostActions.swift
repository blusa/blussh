import AppKit
import CoreImage
import SwiftUI

/// Per-host actions started from the popover: T3 pairing (copy, QR, link to
/// T3 here) and the resource monitor. The pairing URL, which carries the
/// token, is only held in local variables and the clipboard / QR image; it is
/// never logged, persisted or put in a notification.
@MainActor
final class HostActions: ObservableObject {
    /// Host a T3 action is running for (one at a time, like the Omarchy widget)
    @Published private(set) var busyHostId: String?
    /// Short status line for the popover: progress, then the (token-free) result
    @Published private(set) var status: String?

    private let notifier: NotificationManager
    private var qrWindow: NSWindow?
    private var qrDelegate: QRWindowDelegate?
    private var statusClear: DispatchWorkItem?
    /// The running T3 action, so it can be cancelled (which kills its ssh)
    private var task: Task<Void, Never>?
    /// Runs the mint/link processes; swapped for a fake in the smoke harness
    var run: T3.Runner = runProcess

    init(notifier: NotificationManager) {
        self.notifier = notifier
    }

    // MARK: - T3

    /// Minting runs over ssh, so the host must be up (this Mac always is).
    static func canPair(_ host: MonitoredHost) -> Bool {
        host.isT3 && !host.isPlaceholder && (host.isSelf || host.netOnline != false)
    }

    /// Linking also needs a T3 server on this Mac to link the host to.
    func canLink(_ host: MonitoredHost, selfHost: MonitoredHost?) -> Bool {
        Self.canPair(host) && host.isSSHServer && !host.isSelf && selfHost?.isT3 == true
    }

    /// The T3 button: copies a pairing link, or cancels the mint already running for this host.
    func t3ButtonClicked(_ host: MonitoredHost) {
        if busyHostId == host.id { cancel() } else { copyPairingLink(for: host) }
    }

    /// Stops the running T3 action; its ssh/bash process (and children) are killed.
    func cancel() {
        task?.cancel()
    }

    func copyPairingLink(for host: MonitoredHost) {
        guard let magic = startT3(host, progress: "Minting T3 pairing link for \(host.name)…") else { return }
        task = Task {
            let result = await T3.mintPairingURL(target: target(host), magicDNS: magic, label: T3.localShortHostname(), run: run)
            switch result {
            case .success(let url):
                Self.copySensitive(url)
                finish("Pairing link for \(magic) copied · expires in \(T3.pairTTL)")
                notifier.notifyAction(title: "T3 pairing link for \(host.name) copied",
                                      body: "Paste it on the device to pair · expires in \(T3.pairTTL)", failed: false)
            case .failure(let error):
                fail(error, title: "T3 pairing with \(host.name) failed")
            }
        }
    }

    /// Copies just the pairing code, for `t3 environment link` on another
    /// machine: offered even where this Mac runs only the T3 client, so it can
    /// carry the code to another machine's prompt.
    func copyPairingCode(for host: MonitoredHost) {
        guard let magic = startT3(host, progress: "Minting T3 pairing code for \(host.name)…") else { return }
        task = Task {
            let result = await T3.mintPairingCode(target: target(host), magicDNS: magic, label: T3.localShortHostname(), run: run)
            switch result {
            case .success(let code):
                Self.copySensitive(code)
                finish("Pairing code for \(magic) copied · expires in \(T3.pairTTL)")
                notifier.notifyAction(title: "T3 pairing code for \(host.name) copied",
                                      body: "For t3 environment link on another machine · expires in \(T3.pairTTL)",
                                      failed: false)
            case .failure(let error):
                fail(error, title: "T3 pairing with \(host.name) failed")
            }
        }
    }

    func showPairingQR(for host: MonitoredHost) {
        guard let magic = startT3(host, progress: "Minting T3 pairing QR for \(host.name)…") else { return }
        task = Task {
            let result = await T3.mintPairingURL(target: target(host), magicDNS: magic, label: T3.localShortHostname(), run: run)
            switch result {
            case .success(let url):
                guard let image = QRCode.image(for: url) else {
                    finish("Couldn't draw the pairing QR")
                    notifier.notifyAction(title: "T3 pairing with \(host.name) failed",
                                          body: "couldn't draw the pairing QR", failed: true)
                    return
                }
                finish(nil)
                presentQR(image, name: host.name,
                          message: "Scan to pair with \(magic) · expires in \(T3.pairTTL)")
            case .failure(let error):
                fail(error, title: "T3 pairing with \(host.name) failed")
            }
        }
    }

    func link(_ host: MonitoredHost, access: String) {
        guard let magic = startT3(host, progress: "Linking \(host.name) to T3 here (\(access))…") else { return }
        task = Task {
            let result = await T3.link(target: target(host), magicDNS: magic, label: T3.localShortHostname(),
                                       access: access, run: run)
            switch result {
            case .success(let message):
                finish(message)
                notifier.notifyAction(title: "Linked \(host.name) to T3 here",
                                      body: "Agents here can now work on \(host.name) (\(access))", failed: false)
            case .failure(let error):
                fail(error, title: "Linking \(host.name) to T3 failed")
            }
        }
    }

    /// Checks a T3 action can start; returns the host's MagicDNS name.
    private func startT3(_ host: MonitoredHost, progress: String) -> String? {
        guard host.isT3, let magic = host.magicDNS, !host.isPlaceholder else { return nil }
        guard busyHostId == nil else {
            flash("Already minting a T3 pairing link… (esc cancels)")
            return nil
        }
        guard Self.canPair(host) else {
            flash("\(host.name) is offline")
            return nil
        }
        guard host.isSelf || host.isSSHServer else {
            flash("T3 pairing needs SSH access to \(host.name)")
            return nil
        }
        busyHostId = host.id
        setStatus(progress, clearAfter: nil)
        return magic
    }

    private func finish(_ message: String?) {
        busyHostId = nil
        task = nil
        if let message = message { flash(message) } else { setStatus(nil, clearAfter: nil) }
    }

    /// A cancelled run just says so; a failure is notified too.
    private func fail(_ error: T3Error, title: String) {
        finish(error.message)
        if !error.isCancelled { notifier.notifyAction(title: title, body: error.message, failed: true) }
    }

    /// ssh destination, or nil to run on this Mac.
    private func target(_ host: MonitoredHost) -> String? {
        host.isSelf ? nil : host.sshTarget
    }

    private func flash(_ message: String) {
        setStatus(message, clearAfter: 6)
    }

    private func setStatus(_ message: String?, clearAfter seconds: TimeInterval?) {
        statusClear?.cancel()
        status = message
        guard let seconds = seconds else { return }
        let work = DispatchWorkItem { [weak self] in self?.status = nil }
        statusClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Copies `text` marked concealed, so clipboard managers that honour
    /// the nspasteboard.org convention keep it out of their history.
    static func copySensitive(_ text: String) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    // MARK: - QR window

    private func presentQR(_ image: NSImage, name: String, message: String) {
        qrWindow?.close()
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "T3 pairing · \(name)"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: QRPairingView(image: image, name: name, message: message) {
            [weak window] in window?.close()
        })
        let delegate = QRWindowDelegate { [weak self] in
            // Drop the image (the only copy of the link) as soon as the window closes
            self?.qrWindow?.contentView = nil
            self?.qrWindow = nil
            self?.qrDelegate = nil
        }
        window.delegate = delegate
        qrDelegate = delegate
        qrWindow = window
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Monitor

    /// Opens Terminal running the host's best resource monitor over ssh.
    func openMonitor(for host: MonitoredHost) {
        guard host.isSSHServer, !host.isPlaceholder else { return }
        var command = T3.monitorCommand(target: host.sshTarget)
        command[0] = "/usr/bin/ssh"
        let script = "#!/bin/sh\nclear\nexec " + command.map(T3.shellQuote).joined(separator: " ") + "\n"
        let safeId = host.id.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("blussh-monitor-\(String(safeId)).command")
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            flash("Couldn't open the monitor: \(error.localizedDescription)")
            return
        }
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            flash("Terminal not found")
            return
        }
        NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}

private final class QRWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

struct QRPairingView: View {
    let image: NSImage
    let name: String
    let message: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Pair with \(name)").font(.headline)
            Image(nsImage: image)
                .interpolation(.none)
                .accessibilityLabel("T3 pairing QR code")
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
            Button("Done", action: close)
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .fixedSize()
    }
}

enum QRCode {
    /// `text` as a QR code: ECC level M, black on white with a 4-module quiet
    /// zone whatever the theme, `moduleSize` whole points per module so it
    /// stays sharp (nearest neighbour) and scans. Rendered in memory only.
    static func image(for text: String, moduleSize: Int = 6, quietZone: Int = 4) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage,
              let modules = CIContext().createCGImage(output, from: output.extent) else { return nil }

        let side = (modules.width + 2 * quietZone) * moduleSize
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .none
        let inset = CGFloat(quietZone * moduleSize)
        context.draw(modules, in: CGRect(x: inset, y: inset,
                                         width: CGFloat(modules.width * moduleSize),
                                         height: CGFloat(modules.height * moduleSize)))
        guard let qr = context.makeImage() else { return nil }
        return NSImage(cgImage: qr, size: NSSize(width: side, height: side))
    }
}
