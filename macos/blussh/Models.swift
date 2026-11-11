import Foundation

enum GlobalStatus {
    case allOnline
    case someOnline
    case allOffline
    case notInitialized
}

enum HostOrigin: Equatable, Hashable {
    case sshConfig
    case tailscale(tailnet: String)
    case zerotier(networkId: String, networkName: String)

    var groupTitle: String {
        switch self {
        case .sshConfig:
            return "SSH Config"
        case .tailscale(let tailnet):
            return tailnet.isEmpty ? "Tailscale" : "Tailscale · \(tailnet)"
        case .zerotier(let id, let name):
            return name.isEmpty ? "ZeroTier · \(id)" : "ZeroTier · \(name)"
        }
    }

    // Sort key so groups appear in a stable order: ssh config, tailscale, zerotier networks
    var sortKey: String {
        switch self {
        case .sshConfig: return "0"
        case .tailscale: return "1"
        case .zerotier(_, let name): return "2\(name)"
        }
    }
}

struct MonitoredHost: Identifiable {
    let id: String
    let name: String
    let origin: HostOrigin
    let address: String
    var user: String?
    var port: Int = 22
    var netOnline: Bool?
    var sshOnline: Bool?
    var isSSHServer: Bool = false
    var isEnabled: Bool = true
    var isPlaceholder: Bool = false
    /// Alternate identifiers (IPs, DNS names) used to match ssh-config entries against VPN hosts
    var aliases: [String] = []
    /// ssh-config Host alias; when set, the copied command uses it so ssh applies the user's config
    var sshAlias: String?
    /// Tailscale MagicDNS name (DNSName within the tailnet's MagicDNSSuffix), where Tailscale Serve answers
    var magicDNS: String?
    /// Runs a T3 Code server published with Tailscale Serve (persisted detection verdict / user override)
    var isT3: Bool = false
    /// This machine (Tailscale Self): never monitored, only offered T3 pairing
    var isSelf: Bool = false

    /// Combined liveness: VPN state gates first, then the SSH check if applicable.
    var isOnline: Bool {
        if let netOnline = netOnline {
            guard netOnline else { return false }
            if isSSHServer, let sshOnline = sshOnline { return sshOnline }
            return true
        }
        return sshOnline ?? false
    }

    /// ssh destination: `user@alias` when the ssh config supplies them, so ssh applies the user's config
    var sshTarget: String {
        let hostPart = sshAlias ?? address
        return user.map { "\($0)@\(hostPart)" } ?? hostPart
    }

    var sshCommand: String { "ssh \(sshTarget)" }
}

struct SourceError: Identifiable {
    let id: String   // source name
    let message: String
}
