import SwiftUI
import ServiceManagement
import AppKit

struct SettingsView: View {

    @ObservedObject var engine: MonitoringEngine
    @Binding var isShowing: Bool
    @State private var newPath: String = ""
    @State private var filePaths: [String] = UserDefaults.standard.stringArray(forKey: "sshConfigFilePaths") ?? ["~/.ssh/config"]
    @State private var launchAtLogin: Bool = false
    @State private var selectedFrequencyIndex: Double

    @State private var sshSourceEnabled = UserDefaults.standard.bool(forKey: "sshSourceEnabled", defaultValue: true)
    @State private var tailscaleEnabled = UserDefaults.standard.bool(forKey: "tailscaleSourceEnabled", defaultValue: true)
    @State private var zerotierEnabled = UserDefaults.standard.bool(forKey: "zerotierSourceEnabled", defaultValue: true)
    @State private var notificationsEnabled = UserDefaults.standard.bool(forKey: "notificationsEnabled", defaultValue: true)
    @State private var zerotierToken: String = KeychainHelper.read(account: "zerotier-central-token") ?? ""
    @State private var zerotierTokenStatus: String? = nil

    let frequencies: [(label: String, value: TimeInterval)] = [
        ("5s", 5),
        ("10s", 10),
        ("1m", 60),
        ("5m", 300)
    ]

    init(engine: MonitoringEngine, isShowing: Binding<Bool>) {
        self.engine = engine
        self._isShowing = isShowing
        self._selectedFrequencyIndex = State(initialValue: Double(UserDefaults.standard.integer(forKey: "selectedFrequencyIndex", defaultValue: 1)))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button(action: { isShowing = false }) {
                        Text("Back")
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }

                sectionTitle("Sources")

                Toggle("SSH config files", isOn: $sshSourceEnabled)
                    .onChange(of: sshSourceEnabled) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "sshSourceEnabled")
                        engine.refresh()
                    }
                if sshSourceEnabled {
                    sshConfigPathsView
                        .padding(.leading, 20)
                }

                Toggle("Tailscale", isOn: $tailscaleEnabled)
                    .onChange(of: tailscaleEnabled) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "tailscaleSourceEnabled")
                        engine.refresh()
                    }
                if tailscaleEnabled {
                    HStack(spacing: 6) {
                        Image(systemName: TailscaleSource.resolveBinary() != nil ? "checkmark.circle" : "xmark.circle")
                            .foregroundColor(TailscaleSource.resolveBinary() != nil ? .green : .red)
                        Text(TailscaleSource.resolveBinary() ?? "tailscale binary not found")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.leading, 20)
                }

                Toggle("ZeroTier", isOn: $zerotierEnabled)
                    .onChange(of: zerotierEnabled) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "zerotierSourceEnabled")
                        engine.refresh()
                    }
                if zerotierEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Central API token (my.zerotier.com → Account)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack {
                            SecureField("API token", text: $zerotierToken)
                                .textFieldStyle(.roundedBorder)
                            Button("Save") {
                                let trimmed = zerotierToken.trimmingCharacters(in: .whitespacesAndNewlines)
                                KeychainHelper.write(trimmed, account: "zerotier-central-token")
                                zerotierTokenStatus = "Testing…"
                                Task {
                                    let problem = await ZeroTierSource.validateCentralToken(trimmed)
                                    await MainActor.run {
                                        zerotierTokenStatus = problem.map { "✗ \($0)" } ?? "✓ token works"
                                        if problem == nil { engine.refresh() }
                                    }
                                }
                            }
                        }
                        if let status = zerotierTokenStatus {
                            Text(status)
                                .font(.caption)
                                .foregroundColor(status.hasPrefix("✓") ? .green : .red)
                        }
                    }
                    .padding(.leading, 20)
                }

                Divider()

                sectionTitle("Notifications")
                Toggle("Notify when hosts go down or come back", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "notificationsEnabled")
                    }

                Divider()

                sectionTitle("Refresh Frequency")
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("Refresh every:")
                        Text(frequencies[Int(selectedFrequencyIndex)].label)
                            .font(.subheadline)
                            .foregroundColor(.accentColor)
                    }
                    Slider(value: $selectedFrequencyIndex, in: 0...Double(frequencies.count - 1), step: 1)
                        .onChange(of: selectedFrequencyIndex) { _, newValue in
                            let newIndex = Int(newValue)
                            UserDefaults.standard.set(newIndex, forKey: "selectedFrequencyIndex")
                            engine.updateTimer(frequency: frequencies[newIndex].value)
                        }
                }

                Divider()

                sectionTitle("General")
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        Task {
                            do {
                                if newValue {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                print("Failed to perform task launch at login")
                            }
                        }
                    }
                    .onAppear {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }

                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundColor(.secondary)
            .textCase(.uppercase)
    }

    private var sshConfigPathsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(filePaths, id: \.self) { path in
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .foregroundColor(.secondary)
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(role: .destructive) {
                        if let idx = filePaths.firstIndex(of: path) {
                            filePaths.remove(at: idx)
                            UserDefaults.standard.set(filePaths, forKey: "sshConfigFilePaths")
                            engine.refresh()
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack(spacing: 8) {
                Button(action: selectSSHConfigFile) {
                    Image(systemName: "magnifyingglass")
                }
                .help("Search for SSH config file…")
                .buttonStyle(.borderless)

                TextField("SSH config path", text: $newPath)
                    .textFieldStyle(.roundedBorder)

                Button(action: addPath) {
                    Image(systemName: "plus")
                }
                .disabled(newPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderless)
            }
        }
    }

    private func addPath() {
        let trimmed = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        filePaths.append(trimmed)
        UserDefaults.standard.set(filePaths, forKey: "sshConfigFilePaths")
        newPath = ""
        engine.refresh()
    }

    private func selectSSHConfigFile() {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.resolvesAliases = true
        openPanel.showsHiddenFiles = true
        openPanel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")

        openPanel.begin { result in
            if result == .OK, let url = openPanel.url {
                newPath = url.resolvingSymlinksInPath().path
            }
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(engine: MonitoringEngine(), isShowing: .constant(false))
    }
}
