import Foundation

struct DiscoveryResult {
    var hosts: [MonitoredHost] = []
    var error: SourceError? = nil
    /// This machine as the source sees it (Tailscale Self); not monitored
    var selfHost: MonitoredHost? = nil
}

protocol HostSource {
    var name: String { get }
    func discover() async -> DiscoveryResult
}
