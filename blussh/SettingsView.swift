import SwiftUI
import ServiceManagement
import AppKit

@available(macOS 12.0, *)

struct SettingsView: View {
    
    @ObservedObject var sshService: SSHService
    @Binding var isShowing: Bool
    @State private var newPath: String = ""
    @State private var filePaths: [String] = UserDefaults.standard.stringArray(forKey: "sshConfigFilePaths") ?? ["~/.ssh/config"]
    @State private var launchAtLogin: Bool = false
    @State private var selectedFrequencyIndex: Double

    let frequencies: [(label: String, value: TimeInterval)] = [
        ("5s", 5),
        ("10s", 10),
        ("1m", 60),
        ("5m", 300)
    ]

    init(sshService: SSHService, isShowing: Binding<Bool>) {
        self.sshService = sshService
        self._isShowing = isShowing
        self._selectedFrequencyIndex = State(initialValue: Double(UserDefaults.standard.integer(forKey: "selectedFrequencyIndex", defaultValue: 1)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Back (hyperlink)
            HStack {
                Button(action: { isShowing = false }) {
                    Text("Back")
                }
                .buttonStyle(.plain)
                Spacer()
            }
            // SSH Config Files
            Text("SSH Config Files")
                .font(.caption)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 8) {
                if filePaths.isEmpty {
                    Text("No SSH config files added.")
                        .foregroundColor(.secondary)
                } else {
                    List {
                        ForEach(filePaths, id: \.self) { path in
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text")
                                    .foregroundColor(.secondary)
                                Text(path)
                                    .font(.system(.body, design: .monospaced))
                                Spacer()
                                Button(role: .destructive) {
                                    if let idx = filePaths.firstIndex(of: path) {
                                        removePath(at: IndexSet(integer: idx))
                                    }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 1)
                        }
                    }
                    .environment(\.defaultMinListRowHeight, 26)
                    .frame(height: min(160, CGFloat(filePaths.count) * 28 + 12))
                    .listStyle(.inset)
                }
                // Search | Path | +
                HStack(spacing: 8) {
                    Button(action: selectSSHConfigFile) {
                        Image(systemName: "magnifyingglass")
                    }
                    .help("Search for SSH config file…")
                    .buttonStyle(.borderless)

                    TextField("SSH config path", text: $newPath)

                    Button(action: addPath) {
                        Image(systemName: "plus")
                    }
                    .disabled(newPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.borderless)
                }
            }

            Divider()

            // Refresh Frequency
            Text("Refresh Frequency")
                .font(.caption)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Refresh every:")
                    Text(frequencies[Int(selectedFrequencyIndex)].label)
                        .font(.subheadline)
                        .foregroundColor(.accentColor)
                }
                Slider(value: $selectedFrequencyIndex, in: 0...Double(frequencies.count - 1), step: 1)
                    .onChange(of: selectedFrequencyIndex) { oldValue, newValue in
                        let newIndex = Int(newValue)
                        let newFrequency = frequencies[newIndex].value
                        UserDefaults.standard.set(newIndex, forKey: "selectedFrequencyIndex")
                        sshService.updateTimer(frequency: newFrequency)
                    }
            }

            Divider()

            // General
            if #available(macOS 13.0, *) {
                Text("General")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { oldValue, newValue in
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
            }

            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        // No explicit min frame so the presenting sheet controls size
    }

    private func addPath() {
        let trimmed = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        filePaths.append(trimmed)
        UserDefaults.standard.set(filePaths, forKey: "sshConfigFilePaths")
        newPath = ""
        sshService.checkServers()
    }

    private func removePath(at offsets: IndexSet) {
        filePaths.remove(atOffsets: offsets)
        UserDefaults.standard.set(filePaths, forKey: "sshConfigFilePaths")
    }

    private func selectSSHConfigFile() {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.resolvesAliases = true // Important for resolving symlinks

        openPanel.begin { (result) -> Void in
            if result == .OK {
                if let url = openPanel.url {
                    do {
                        // Resolve symlinks before creating the bookmark
                        let resolvedUrl = url.resolvingSymlinksInPath()
                        let bookmarkData = try resolvedUrl.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                        UserDefaults.standard.set(bookmarkData, forKey: "sshConfigBookmark")
                        // Fill the text field; user confirms by pressing +
                        newPath = resolvedUrl.path
                    } catch {
                        print("Failed to create bookmark: \(error)")
                    }
                }
            }
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(sshService: SSHService(), isShowing: .constant(false))
    }
}

