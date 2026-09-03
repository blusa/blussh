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
            if let host = currentConfig["host"], !hostIsPattern(host) {
                hosts.append(MonitoredHost(
                    id: "ssh:\(host)",
                    name: host,
                    origin: .sshConfig,
                    address: currentConfig["hostname"] ?? host,
                    user: currentConfig["user"],
                    port: Int(currentConfig["port"] ?? "22") ?? 22,
                    isSSHServer: true,
                    sshAlias: host
                ))
            }
            currentConfig = [:]
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
