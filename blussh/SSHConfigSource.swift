import Foundation

struct SSHConfigSource: HostSource {
    let name = "SSH Config"

    func discover() async -> DiscoveryResult {
        let paths = UserDefaults.standard.stringArray(forKey: "sshConfigFilePaths") ?? ["~/.ssh/config"]
        var hosts: [MonitoredHost] = []
        var errors: [String] = []

        for path in paths {
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
            do {
                let contents = try String(contentsOf: url, encoding: .utf8)
                hosts.append(contentsOf: parse(contents))
            } catch {
                errors.append("\((path as NSString).lastPathComponent): \(error.localizedDescription)")
            }
        }

        var result = DiscoveryResult(hosts: hosts)
        if !errors.isEmpty {
            result.error = SourceError(id: name, message: errors.joined(separator: " · "))
        }
        return result
    }

    func parse(_ contents: String) -> [MonitoredHost] {
        var hosts: [MonitoredHost] = []
        var currentConfig: [String: String] = [:]

        func commit() {
            defer { currentConfig = [:] }
            // A Host line may list several names ("Host devbox devbox.odinedge.xyz");
            // the first non-pattern one is canonical, the rest are aliases.
            let names = (currentConfig["host"] ?? "")
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
                .filter { !hostIsPattern($0) }
            guard let name = names.first else { return }
            let address = currentConfig["hostname"] ?? name
            hosts.append(MonitoredHost(
                id: "ssh:\(name)",
                name: name,
                origin: .sshConfig,
                address: address,
                user: currentConfig["user"],
                port: Int(currentConfig["port"] ?? "22") ?? 22,
                isSSHServer: true,
                aliases: (names + [address]).map { $0.lowercased() },
                sshAlias: name
            ))
        }

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.starts(with: "#") { continue }

            if trimmed.lowercased().starts(with: "host ") {
                commit()
            }

            let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                currentConfig[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        commit()
        return hosts
    }

    private func hostIsPattern(_ host: String) -> Bool {
        host.contains("*") || host.contains("?") || host.contains("!")
    }
}
