import SwiftUI

struct StatusMenuView: View {
    @ObservedObject var sshService: SSHService
    @State private var lastUpdatedString: String = ""
    @State private var showingSettings = false

    let updateTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(sshService: SSHService) {
        self.sshService = sshService
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("BluSSH")
                    .font(.headline)
                Spacer()
                Circle()
                    .frame(width: 10, height: 10)
                    .foregroundColor(statusColor(for: sshService.globalStatus))
            }

            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(Array(Dictionary(grouping: sshService.serverStatuses, by: { $0.group }).keys.sorted()), id: \.self) { group in
                        Section(header:
                                    Text(group)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .textCase(.uppercase)
                                        .padding(.top, 8)
                        ) {
                            ForEach(sshService.serverStatuses.filter { $0.group == group }) { server in
                                HStack {
                                    Toggle("", isOn: Binding(
                                        get: { server.isEnabled },
                                        set: { newValue in
                                            if let index = sshService.serverStatuses.firstIndex(where: { $0.id == server.id }) {
                                                sshService.serverStatuses[index].isEnabled = newValue
                                                var enabledDict = UserDefaults.standard.dictionary(forKey: "enabledHosts") as? [String: Bool] ?? [:]
                                                enabledDict[server.host] = newValue
                                                UserDefaults.standard.set(enabledDict, forKey: "enabledHosts")
                                            }
                                        }
                                    ))
                                    VStack(alignment: .leading) {
                                        Text(server.host).font(.headline)
                                        Text(subtitle(for: server))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Circle()
                                        .frame(width: 10, height: 10)
                                        .foregroundColor(server.isOnline ? .green : .red)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 800)

            Divider()

            HStack {
                Button {
                    sshService.checkServers()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14))
                }
                .buttonStyle(.borderless)
                .frame(width: 24, height: 24)

                Button {
                    showingSettings.toggle()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                }
                .buttonStyle(.borderless)
                .frame(width: 24, height: 24)

                Text(lastUpdatedString)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        .frame(width: 320)
        .onReceive(updateTimer) { _ in
            updateLastUpdatedString()
        }
        .onAppear {
            updateLastUpdatedString()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(sshService: sshService, isShowing: $showingSettings)
                .frame(width: 340, height: 420)
        }
    }

    private func statusColor(for status: GlobalStatus) -> Color {
        switch status {
        case .allOnline:
            return .green
        case .someOnline:
            return .yellow
        case .allOffline:
            return .red
        }
    }

    private func subtitle(for server: SSHServer) -> String {
        if let user = server.user {
            return "\(user)@\(server.hostName)"
        } else {
            return server.hostName
        }
    }

    private func updateLastUpdatedString() {
        if let lastUpdated = sshService.lastUpdated {
            let interval = Date().timeIntervalSince(lastUpdated)
            if interval < 2 {
                lastUpdatedString = "Refreshed just now"
            } else {
                lastUpdatedString = "Refreshed \(Int(interval))s. ago"
            }
        } else {
            lastUpdatedString = "Not refreshed yet"
        }
    }
}

extension UserDefaults {
    func integer(forKey defaultName: String, defaultValue: Int) -> Int {
        if object(forKey: defaultName) == nil {
            return defaultValue
        }
        return integer(forKey: defaultName)
    }
}
