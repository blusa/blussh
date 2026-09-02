import Foundation

struct ZeroTierSource: HostSource {
    let name = "ZeroTier"

    // Central marks members online while seen within ~60s; give it slack for polling jitter
    static let onlineWindow: TimeInterval = 300

    func discover() async -> DiscoveryResult {
        guard let authToken = localAuthToken() else {
            return DiscoveryResult(error: SourceError(id: name, message: "ZeroTier not installed (no authtoken.secret)"))
        }

        let joined: [(id: String, name: String, ok: Bool)]
        let selfNodeId: String
        do {
            joined = try await joinedNetworks(authToken: authToken)
            selfNodeId = try await nodeAddress(authToken: authToken)
        } catch {
            return DiscoveryResult(error: SourceError(id: name, message: "local API: \(error.localizedDescription)"))
        }

        guard let centralToken = KeychainHelper.read(account: "zerotier-central-token"), !centralToken.isEmpty else {
            let hosts = joined.map { placeholder(network: $0, message: "Set a ZeroTier Central token in Settings") }
            return DiscoveryResult(hosts: hosts, error: SourceError(id: name, message: "no Central API token configured"))
        }

        var hosts: [MonitoredHost] = []
        var errors: [String] = []
        for network in joined {
            guard network.ok else {
                hosts.append(placeholder(network: network, message: "Network unreachable (status not OK)"))
                continue
            }
            do {
                hosts.append(contentsOf: try await members(of: network, centralToken: centralToken, excluding: selfNodeId))
            } catch {
                hosts.append(placeholder(network: network, message: "Central: \(error.localizedDescription)"))
                errors.append("\(network.name): \(error.localizedDescription)")
            }
        }

        var result = DiscoveryResult(hosts: hosts)
        if !errors.isEmpty {
            result.error = SourceError(id: name, message: errors.joined(separator: " · "))
        }
        return result
    }

    private func placeholder(network: (id: String, name: String, ok: Bool), message: String) -> MonitoredHost {
        MonitoredHost(
            id: "zt:\(network.id):placeholder",
            name: message,
            origin: .zerotier(networkId: network.id, networkName: network.name),
            address: "",
            isEnabled: false,
            isPlaceholder: true
        )
    }

    private func localAuthToken() -> String? {
        let paths = [
            NSString("~/Library/Application Support/ZeroTier/One/authtoken.secret").expandingTildeInPath,
            "/Library/Application Support/ZeroTier/One/authtoken.secret"
        ]
        for path in paths {
            if let token = try? String(contentsOfFile: path, encoding: .utf8) {
                return token.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func joinedNetworks(authToken: String) async throws -> [(id: String, name: String, ok: Bool)] {
        let data = try await get(url: "http://localhost:9993/network", headers: ["X-ZT1-Auth": authToken])
        guard let networks = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw simpleError("unexpected /network response")
        }
        return networks.compactMap { net in
            guard let id = net["id"] as? String else { return nil }
            let netName = net["name"] as? String ?? ""
            return (id: id, name: netName, ok: (net["status"] as? String) == "OK")
        }
    }

    private func nodeAddress(authToken: String) async throws -> String {
        let data = try await get(url: "http://localhost:9993/status", headers: ["X-ZT1-Auth": authToken])
        guard let status = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let address = status["address"] as? String else {
            throw simpleError("unexpected /status response")
        }
        return address
    }

    private func members(of network: (id: String, name: String, ok: Bool),
                         centralToken: String, excluding selfNodeId: String) async throws -> [MonitoredHost] {
        let data = try await get(
            url: "https://api.zerotier.com/api/v1/network/\(network.id)/member",
            headers: ["Authorization": "token \(centralToken)"])
        guard let members = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw simpleError("unexpected member list response")
        }

        var hosts: [MonitoredHost] = []
        for member in members {
            guard let nodeId = member["nodeId"] as? String, nodeId != selfNodeId else { continue }
            if member["hidden"] as? Bool == true { continue }
            let config = member["config"] as? [String: Any]
            if config?["authorized"] as? Bool == false { continue }

            let memberName = (member["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? nodeId
            let ip = (config?["ipAssignments"] as? [String])?.first

            // Central renamed lastOnline -> lastSeen at some point; accept either (epoch ms)
            let lastSeenMs = (member["lastSeen"] as? Double) ?? (member["lastOnline"] as? Double) ?? 0
            let online = lastSeenMs > 0
                && Date(timeIntervalSince1970: lastSeenMs / 1000).timeIntervalSinceNow > -Self.onlineWindow

            var aliases = [memberName.lowercased(), nodeId.lowercased()]
            aliases.append(contentsOf: (config?["ipAssignments"] as? [String] ?? []).map { $0.lowercased() })

            hosts.append(MonitoredHost(
                id: "zt:\(network.id):\(nodeId)",
                name: memberName,
                origin: .zerotier(networkId: network.id, networkName: network.name),
                address: ip ?? nodeId,
                netOnline: online,
                aliases: aliases
            ))
        }
        hosts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return hosts
    }

    private func get(url: String, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 10)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw simpleError("HTTP \(http.statusCode)")
        }
        return data
    }

    private func simpleError(_ message: String) -> Error {
        NSError(domain: "blussh.zerotier", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
