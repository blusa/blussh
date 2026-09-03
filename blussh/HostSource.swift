import Foundation

struct DiscoveryResult {
    var hosts: [MonitoredHost] = []
    var error: SourceError? = nil
}

protocol HostSource {
    var name: String { get }
    func discover() async -> DiscoveryResult
}
