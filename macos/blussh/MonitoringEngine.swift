import Foundation
import Network

final class MonitoringEngine: ObservableObject {
    @Published var hosts: [MonitoredHost] = []
    @Published var sourceErrors: [SourceError] = []
    @Published var lastUpdated: Date? = nil
    @Published var globalStatus: GlobalStatus = .notInitialized

    private let notifier = NotificationManager()
    private var timer: Timer?
    private var isRefreshing = false

    // Debounce: a reading must repeat this many times to flip the confirmed state
    private let confirmationThreshold = 2
    private var pendingStreaks: [String: (state: Bool, count: Int)] = [:]

    func start() {
        notifier.requestPermission()
        refresh()
    }

    func updateTimer(frequency: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: frequency, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        Task { await runCycle() }
    }

    func setEnabled(_ enabled: Bool, hostId: String) {
        persist(enabled, hostId: hostId, key: "hostEnabled/v2")
        if let index = hosts.firstIndex(where: { $0.id == hostId }) {
            hosts[index].isEnabled = enabled
        }
    }

    func setIsSSHServer(_ isSSH: Bool, hostId: String) {
        persist(isSSH, hostId: hostId, key: "hostIsSSH/v2")
        if let index = hosts.firstIndex(where: { $0.id == hostId }) {
            hosts[index].isSSHServer = isSSH
            hosts[index].sshOnline = nil
        }
    }

    // MARK: - Cycle

    private func runCycle() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        var sources: [HostSource] = []
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "sshSourceEnabled") as? Bool ?? true { sources.append(SSHConfigSource()) }
        if defaults.object(forKey: "tailscaleSourceEnabled") as? Bool ?? true { sources.append(TailscaleSource()) }
        if defaults.object(forKey: "zerotierSourceEnabled") as? Bool ?? true { sources.append(ZeroTierSource()) }

        var results: [DiscoveryResult] = []
        await withTaskGroup(of: DiscoveryResult.self) { group in
            for source in sources {
                group.addTask { await source.discover() }
            }
            for await result in group { results.append(result) }
        }

        var discovered = merge(results.flatMap { $0.hosts })
        let errors = results.compactMap { $0.error }

        // Apply persisted per-host overrides
        let enabledDict = defaults.dictionary(forKey: "hostEnabled/v2") as? [String: Bool] ?? [:]
        var sshDict = defaults.dictionary(forKey: "hostIsSSH/v2") as? [String: Bool] ?? [:]
        for i in discovered.indices {
            guard !discovered[i].isPlaceholder else { continue }
            discovered[i].isEnabled = enabledDict[discovered[i].id] ?? true
            if let override = sshDict[discovered[i].id] {
                discovered[i].isSSHServer = override
            }
        }

        // Auto-detect SSH: first time a VPN host is seen net-online, probe port 22 once
        await withTaskGroup(of: (Int, Bool).self) { group in
            for (i, host) in discovered.enumerated() {
                guard !host.isPlaceholder, host.netOnline == true,
                      sshDict[host.id] == nil, !host.isSSHServer else { continue }
                group.addTask { [self] in (i, await checkTCP(host: host.address, port: host.port)) }
            }
            for await (i, responds) in group {
                discovered[i].isSSHServer = responds
                discovered[i].sshOnline = responds ? true : nil
                sshDict[discovered[i].id] = responds
            }
        }
        defaults.set(sshDict, forKey: "hostIsSSH/v2")

        // TCP checks, concurrently
        var checked = discovered
        await withTaskGroup(of: (Int, Bool).self) { group in
            for (i, host) in checked.enumerated() {
                guard host.isEnabled, host.isSSHServer, !host.isPlaceholder,
                      host.netOnline != false, host.sshOnline == nil else { continue }
                group.addTask { [self] in (i, await checkTCP(host: host.address, port: host.port)) }
            }
            for await (i, online) in group { checked[i].sshOnline = online }
        }
        // Hosts the VPN reports offline are down; no point probing
        for i in checked.indices where checked[i].isSSHServer && checked[i].netOnline == false {
            checked[i].sshOnline = false
        }

        let transitions = applyDebounce(to: checked)
        let final = checked

        await MainActor.run {
            self.hosts = final
            self.sourceErrors = errors
            self.lastUpdated = Date()
            self.globalStatus = Self.computeGlobalStatus(final)
            for (host, isUp) in transitions {
                self.notifier.notify(host: host, isUp: isUp)
            }
        }
    }

    // MARK: - Merge ssh-config entries into matching VPN hosts

    func merge(_ hosts: [MonitoredHost]) -> [MonitoredHost] {
        var vpnHosts = hosts.filter { $0.origin != .sshConfig }
        let sshHosts = hosts.filter { $0.origin == .sshConfig }

        var aliasIndex: [String: Int] = [:]
        for (i, host) in vpnHosts.enumerated() {
            for alias in host.aliases { aliasIndex[alias] = i }
        }

        var unmatched: [MonitoredHost] = []
        for sshHost in sshHosts {
            if let i = aliasIndex[sshHost.address.lowercased()] ?? aliasIndex[sshHost.name.lowercased()] {
                vpnHosts[i].user = sshHost.user
                vpnHosts[i].port = sshHost.port
                vpnHosts[i].isSSHServer = true
                vpnHosts[i].sshAlias = sshHost.name
            } else {
                unmatched.append(sshHost)
            }
        }
        return unmatched + vpnHosts
    }

    // MARK: - Debounce

    func applyDebounce(to hosts: [MonitoredHost]) -> [(MonitoredHost, Bool)] {
        let defaults = UserDefaults.standard
        var confirmed = defaults.dictionary(forKey: "hostConfirmedState/v2") as? [String: Bool] ?? [:]
        var transitions: [(MonitoredHost, Bool)] = []

        for host in hosts where host.isEnabled && !host.isPlaceholder {
            let current = host.isOnline
            guard let previous = confirmed[host.id] else {
                confirmed[host.id] = current   // first sighting: baseline, no notification
                continue
            }
            if current == previous {
                pendingStreaks[host.id] = nil
                continue
            }
            var streak = pendingStreaks[host.id].flatMap { $0.state == current ? $0 : nil }
                ?? (state: current, count: 0)
            streak.count += 1
            if streak.count >= confirmationThreshold {
                confirmed[host.id] = current
                pendingStreaks[host.id] = nil
                transitions.append((host, current))
            } else {
                pendingStreaks[host.id] = streak
            }
        }

        defaults.set(confirmed, forKey: "hostConfirmedState/v2")
        return transitions
    }

    // MARK: - Helpers

    private static func computeGlobalStatus(_ hosts: [MonitoredHost]) -> GlobalStatus {
        let enabled = hosts.filter { $0.isEnabled && !$0.isPlaceholder }
        guard !enabled.isEmpty else { return .notInitialized }
        if enabled.allSatisfy({ $0.isOnline }) { return .allOnline }
        if enabled.allSatisfy({ !$0.isOnline }) { return .allOffline }
        return .someOnline
    }

    private func persist(_ value: Bool, hostId: String, key: String) {
        var dict = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        dict[hostId] = value
        UserDefaults.standard.set(dict, forKey: key)
    }

    private func checkTCP(host: String, port: Int, timeout: TimeInterval = 5) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        let queue = DispatchQueue(label: "blussh.tcpcheck")

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            var finished = false

            func finish(_ result: Bool) {
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: queue.async { finish(true) }
                case .failed, .cancelled: queue.async { finish(false) }
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
            connection.start(queue: queue)
        }
    }
}
