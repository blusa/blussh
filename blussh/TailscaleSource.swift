import Foundation

struct TailscaleSource: HostSource {
    let name = "Tailscale"

    static let defaultBinaryPaths = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale"
    ]

    static func resolveBinary() -> String? {
        if let custom = UserDefaults.standard.string(forKey: "tailscaleBinaryPath"),
           !custom.isEmpty, FileManager.default.isExecutableFile(atPath: custom) {
            return custom
        }
        return defaultBinaryPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func discover() async -> DiscoveryResult {
        guard let binary = Self.resolveBinary() else {
            return DiscoveryResult(error: SourceError(id: name, message: "tailscale binary not found"))
        }

        let data: Data
        do {
            data = try await runProcess(binary, arguments: ["status", "--json"])
        } catch {
            return DiscoveryResult(error: SourceError(id: name, message: error.localizedDescription))
        }

        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let peers = root["Peer"] as? [String: [String: Any]] else {
            return DiscoveryResult(error: SourceError(id: name, message: "unexpected status --json output"))
        }

        let tailnet = (root["CurrentTailnet"] as? [String: Any])?["Name"] as? String
            ?? root["MagicDNSSuffix"] as? String ?? ""

        var hosts: [MonitoredHost] = []
        for peer in peers.values {
            guard let hostName = peer["HostName"] as? String else { continue }
            // Mullvad exit nodes and the like have no MagicDNS name worth showing
            let dnsName = (peer["DNSName"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let ips = peer["TailscaleIPs"] as? [String] ?? []
            let address = dnsName ?? ips.first(where: { !$0.contains(":") }) ?? hostName
            let shortName = dnsName?.components(separatedBy: ".").first ?? hostName

            var aliases = ips.map { $0.lowercased() } + [shortName.lowercased(), hostName.lowercased()]
            if let dnsName = dnsName { aliases.append(dnsName.lowercased()) }

            hosts.append(MonitoredHost(
                id: "ts:\(shortName.lowercased())",
                name: shortName,
                origin: .tailscale(tailnet: tailnet),
                address: address,
                netOnline: peer["Online"] as? Bool ?? false,
                aliases: aliases
            ))
        }
        hosts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return DiscoveryResult(hosts: hosts)
    }

    private func runProcess(_ path: String, arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()
            process.terminationHandler = { proc in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "blussh.tailscale", code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "tailscale exited with status \(proc.terminationStatus)"]))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
