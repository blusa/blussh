import SwiftUI

struct StatusMenuView: View {
    @ObservedObject var engine: MonitoringEngine
    @State private var lastUpdatedString: String = ""
    @State private var showingSettings = false
    @State private var hoveredHostId: String? = nil
    @State private var copiedHostId: String? = nil

    let updateTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var groups: [(origin: HostOrigin, hosts: [MonitoredHost])] {
        Dictionary(grouping: engine.hosts, by: { $0.origin })
            .sorted { $0.key.sortKey < $1.key.sortKey }
            .map { (origin: $0.key, hosts: $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("BluSSH")
                    .font(.headline)
                Spacer()
                Text(onlineSummary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Circle()
                    .frame(width: 10, height: 10)
                    .foregroundColor(statusColor(for: engine.globalStatus))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(groups, id: \.origin) { group in
                        groupHeader(group)
                        ForEach(group.hosts) { host in
                            if host.isPlaceholder {
                                placeholderRow(host)
                            } else {
                                hostRow(host)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 800)

            if !engine.sourceErrors.isEmpty {
                ForEach(engine.sourceErrors) { error in
                    Label("\(error.id): \(error.message)", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .lineLimit(2)
                }
            }

            Divider()

            HStack {
                Button {
                    engine.refresh()
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
        .frame(width: 340)
        .onReceive(updateTimer) { _ in
            updateLastUpdatedString()
        }
        .onAppear {
            updateLastUpdatedString()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(engine: engine, isShowing: $showingSettings)
                .frame(width: 360, height: 520)
        }
    }

    // MARK: - Rows

    private func groupHeader(_ group: (origin: HostOrigin, hosts: [MonitoredHost])) -> some View {
        let real = group.hosts.filter { !$0.isPlaceholder && $0.isEnabled }
        let online = real.filter { $0.isOnline }.count
        return HStack {
            Text(group.origin.groupTitle)
                .font(.caption)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            Spacer()
            if !real.isEmpty {
                Text("\(online)/\(real.count)")
                    .font(.caption2)
                    .foregroundColor(online == real.count ? .secondary : .orange)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private func placeholderRow(_ host: MonitoredHost) -> some View {
        Text(host.name)
            .font(.caption)
            .foregroundColor(.secondary)
            .italic()
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
    }

    private func hostRow(_ host: MonitoredHost) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { host.isEnabled },
                set: { engine.setEnabled($0, hostId: host.id) }
            ))
            .labelsHidden()

            VStack(alignment: .leading, spacing: 1) {
                Text(host.name).font(.headline)
                Text(subtitle(for: host))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if host.isSSHServer {
                Text("ssh")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(sshBadgeColor(host).opacity(0.2)))
                    .foregroundColor(sshBadgeColor(host))
            }

            Circle()
                .frame(width: 10, height: 10)
                .foregroundColor(dotColor(host))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(backgroundColor(host))
                .padding(.horizontal, -6)
                .padding(.vertical, -2)
        )
        .contentShape(Rectangle())
        .onHover { isHovering in
            hoveredHostId = isHovering ? host.id : nil
            if isHovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .onTapGesture {
            copyToClipboard(host.sshCommand)
            copiedHostId = host.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                copiedHostId = nil
            }
        }
        .contextMenu {
            Button("Copy ssh command") { copyToClipboard(host.sshCommand) }
            Button("Copy address") { copyToClipboard(host.address) }
            Toggle("Monitor SSH port", isOn: Binding(
                get: { host.isSSHServer },
                set: { engine.setIsSSHServer($0, hostId: host.id) }
            ))
        }
    }

    // MARK: - Helpers

    private var onlineSummary: String {
        let enabled = engine.hosts.filter { $0.isEnabled && !$0.isPlaceholder }
        guard !enabled.isEmpty else { return "" }
        return "\(enabled.filter { $0.isOnline }.count)/\(enabled.count) online"
    }

    private func subtitle(for host: MonitoredHost) -> String {
        if let user = host.user {
            return "\(user)@\(host.address)"
        }
        return host.address
    }

    private func dotColor(_ host: MonitoredHost) -> Color {
        guard host.isEnabled else { return .gray }
        if host.isOnline { return .green }
        // Net up but ssh down is a distinct, more curious failure
        if host.netOnline == true && host.sshOnline == false { return .orange }
        return .red
    }

    private func sshBadgeColor(_ host: MonitoredHost) -> Color {
        guard host.isEnabled else { return .gray }
        switch host.sshOnline {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return .gray
        }
    }

    private func backgroundColor(_ host: MonitoredHost) -> Color {
        if copiedHostId == host.id {
            return Color.green.opacity(0.2)
        } else if hoveredHostId == host.id {
            return Color.blue.opacity(0.1)
        }
        return Color.clear
    }

    private func statusColor(for status: GlobalStatus) -> Color {
        switch status {
        case .allOnline: return .green
        case .someOnline: return .orange
        case .allOffline: return .red
        case .notInitialized: return .gray
        }
    }

    private func updateLastUpdatedString() {
        if let lastUpdated = engine.lastUpdated {
            let interval = Date().timeIntervalSince(lastUpdated)
            lastUpdatedString = interval < 2 ? "Refreshed just now" : "Refreshed \(Int(interval))s. ago"
        } else {
            lastUpdatedString = "Not refreshed yet"
        }
    }

    private func copyToClipboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

extension UserDefaults {
    func integer(forKey defaultName: String, defaultValue: Int) -> Int {
        if object(forKey: defaultName) == nil {
            return defaultValue
        }
        return integer(forKey: defaultName)
    }

    func bool(forKey defaultName: String, defaultValue: Bool) -> Bool {
        if object(forKey: defaultName) == nil {
            return defaultValue
        }
        return bool(forKey: defaultName)
    }
}
