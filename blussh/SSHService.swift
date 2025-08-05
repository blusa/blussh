import Foundation
import Network

enum GlobalStatus {
    case allOnline
    case someOnline
    case allOffline
}

struct SSHServer: Identifiable {
    let id = UUID()
    let host: String
    let hostName: String
    let user: String?
    let port: Int
    var isOnline: Bool = false
    var group: String = ""
    var isEnabled: Bool = true
}

class SSHService: ObservableObject {
    @Published var serverStatuses: [SSHServer] = []
    @Published var lastUpdated: Date? = nil
    @Published var globalStatus: GlobalStatus = .allOnline
    var timer: Timer?

    func updateTimer(frequency: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: frequency, repeats: true) { [weak self] _ in
            self?.checkServers()
        }
    }

    func checkServers() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }

            var allServers: [SSHServer] = []

            if let bookmarkData = UserDefaults.standard.data(forKey: "sshConfigBookmark") {
                var isStale = false
                do {
                    let url = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
                    if isStale {
                        // Bookmark is stale, try to create a new one
                        let newBookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                        UserDefaults.standard.set(newBookmarkData, forKey: "sshConfigBookmark")
                    }

                    if url.startAccessingSecurityScopedResource() {
                        do {
                            let configContents = try String(contentsOf: url, encoding: .utf8)
                            let lines = configContents.components(separatedBy: .newlines)
                            
                            var servers: [SSHServer] = []
                            var currentConfig: [String: String] = [:]
                            
                            func commitCurrentServer() {
                                if let host = currentConfig["host"] {
                                    let hostNameToUse = currentConfig["hostname"] ?? host
                                    let portToUse = Int(currentConfig["port"] ?? "22") ?? 22
                                    let userToUse = currentConfig["user"]
                                    servers.append(SSHServer(host: host, hostName: hostNameToUse, user: userToUse, port: portToUse))
                                }
                                currentConfig = [:]
                            }
                            
                            for line in lines {
                                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                                if trimmedLine.isEmpty || trimmedLine.starts(with: "#") { continue }
                                
                                if trimmedLine.lowercased().starts(with: "host ") {
                                    commitCurrentServer()
                                }
                                
                                let parts = trimmedLine.split(separator: " ", maxSplits: 1).map(String.init)
                                if parts.count == 2 {
                                    let key = parts[0].lowercased()
                                    let value = parts[1]
                                    currentConfig[key] = value
                                }
                            }
                            commitCurrentServer()
                            allServers.append(contentsOf: servers)
                        } catch {
                            print("Error reading SSH config file: \(error)")
                        }
                        url.stopAccessingSecurityScopedResource()
                    } else {
                        print("Could not start accessing security scoped resource.")
                    }
                } catch {
                    print("Error resolving bookmark: \(error)")
                    UserDefaults.standard.removeObject(forKey: "sshConfigBookmark") // Remove stale bookmark
                }
            } else {
                print("No SSH config bookmark found.")
            }
            
            var finalServers: [SSHServer]
            if allServers.isEmpty {
                finalServers = [SSHServer(host: "No hosts found in any config", hostName: "", user: nil, port: 0, isOnline: false)]
            } else {
                let enabledDict = UserDefaults.standard.dictionary(forKey: "enabledHosts") as? [String: Bool] ?? [:]
                finalServers = allServers.map { server in
                    var mutableServer = server
                    mutableServer.isEnabled = enabledDict[server.host] ?? true
                    if mutableServer.isEnabled {
                        mutableServer.isOnline = self.checkServer(host: server.hostName, port: server.port)
                    }
                    mutableServer.group = self.extractGroup(from: server.hostName)
                    return mutableServer
                }
            }
            
            DispatchQueue.main.async {
                self.serverStatuses = finalServers
                self.lastUpdated = Date()
                
                let enabledServers = finalServers.filter { $0.isEnabled }
                if enabledServers.allSatisfy({ $0.isOnline }) {
                    self.globalStatus = .allOnline
                } else if enabledServers.allSatisfy({ !$0.isOnline }) {
                    self.globalStatus = .allOffline
                } else {
                    self.globalStatus = .someOnline
                }
            }
        }
    }

    private func extractGroup(from hostName: String) -> String {
        let components = hostName.split(separator: ".")
        if components.count >= 2 {
            return components.suffix(2).joined(separator: ".")
        }
        return hostName
    }

    private func checkServer(host: String, port: Int) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var isOnline = false
        var hasSignaled = false

        guard let port = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return false
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)

        connection.stateUpdateHandler = { (newState) in
            guard !hasSignaled else { return }

            switch newState {
            case .ready:
                isOnline = true
                hasSignaled = true
                semaphore.signal()
            case .failed, .cancelled:
                hasSignaled = true
                semaphore.signal()
            default:
                break
            }
        }

        connection.start(queue: .global())
        _ = semaphore.wait(timeout: .now() + 2)
        
        connection.cancel()
        
        return isOnline
    }
}