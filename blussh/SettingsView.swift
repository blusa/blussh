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
        Form {
            Section(header: Text("SSH Config Files")) {
                List {
                    ForEach(filePaths, id: \.self) { path in
                        Text(path)
                    }
                    .onDelete(perform: removePath)
                }

                HStack {
                    TextField("Add new path", text: $newPath)
                    Button("Add") {
                        addPath()
                    }
                }
                HStack {
                    Spacer()
                    Button("Select SSH Config File") {
                        selectSSHConfigFile()
                    }
                }
            }

            Section(header: Text("Refresh Frequency")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Refresh every: \(frequencies[Int(selectedFrequencyIndex)].label)")
                        .font(.subheadline)

                    Slider(value: $selectedFrequencyIndex, in: 0...Double(frequencies.count - 1), step: 1)
                        .onChange(of: selectedFrequencyIndex) { oldValue, newValue in
                            let newIndex = Int(newValue)
                            let newFrequency = frequencies[newIndex].value
                            UserDefaults.standard.set(newIndex, forKey: "selectedFrequencyIndex")
                            sshService.updateTimer(frequency: newFrequency)
                        }
                }
            }

            if #available(macOS 13.0, *) {
                Section(header: Text("General")) {
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
                                    print("Failed to \(newValue ? "enable" : "disable") launch at login: \(error.localizedDescription)")
                                }
                            }
                        }
                        .onAppear {
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                }
            }
        }
        .frame(minWidth: 300, minHeight: 350) // Increased size
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    isShowing = false
                }
            }
        }
    }

    private func addPath() {
        guard !newPath.isEmpty else { return }
        filePaths.append(newPath)
        UserDefaults.standard.set(filePaths, forKey: "sshConfigFilePaths")
        newPath = ""
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
        

        openPanel.begin { (result) -> Void in
            if result == .OK {
                if let url = openPanel.url {
                    do {
                        let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                        UserDefaults.standard.set(bookmarkData, forKey: "sshConfigBookmark")
                        // Optionally, add the path to the displayed list if desired
                        if !filePaths.contains(url.path) {
                            filePaths.append(url.path)
                            UserDefaults.standard.set(filePaths, forKey: "sshConfigFilePaths")
                        }
                        sshService.checkServers() // Re-check servers after selecting new config
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

