import Foundation

/// T3 Code pairing and the resource monitor, mirroring `omarchy/blussh.py`
/// (see docs/monitoring-spec.md, "Host actions: T3 pairing and monitor").
///
/// Token hygiene: `t3 pair` output (which carries the pairing token) only
/// ever lives in memory here. Nothing in this file prints, logs or persists
/// it, and every error message is built from redacted output.
enum T3 {
    static let probeTimeout: TimeInterval = 5
    // Whole `t3 pair` run over ssh. A wedged host or T3 server must not hold the
    // popover for minutes; the one slow case is a first `npx -y t3` download, which
    // reports a timeout and works on the next try once npx has cached it.
    static let pairTimeout: TimeInterval = 60
    static let pairTTL = "1h"

    // What the T3 Code web client serves at `/`. Every path answers with the same
    // SPA, so a route can't tell T3 from another web app; its HTML can.
    private static let marker = try! NSRegularExpression(
        pattern: #"<title>\s*T3 Code\b|["']t3code:"#, options: [.caseInsensitive])
    private static let pairingURL = try! NSRegularExpression(
        pattern: #"^\s*Pairing URL:\s*(\S+)"#, options: [.anchorsMatchLines])
    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]")
    // token=…, token%3D… (the url-encoded App link) and "Token: …"
    private static let token = try! NSRegularExpression(
        pattern: #"(token\s*(?:=|%3D|:)\s*)[^\s&"']+"#, options: [.caseInsensitive])

    // MARK: - Detection

    static func isT3Page(status: Int, contentType: String?, body: String?) -> Bool {
        guard status == 200, (contentType ?? "").lowercased().contains("html") else { return false }
        let body = body ?? ""
        return marker.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) != nil
    }

    private static let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = probeTimeout
        config.timeoutIntervalForResource = probeTimeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()

    /// Is a T3 Code server published with Tailscale Serve on this host?
    ///
    /// Returns nil only when the name doesn't resolve (a MagicDNS hiccup worth
    /// retrying); a refused connection, TLS error or timeout is a "no".
    static func probe(magicDNS: String) async -> Bool? {
        guard let url = URL(string: "https://\(magicDNS)/") else { return false }
        var request = URLRequest(url: url, timeoutInterval: probeTimeout)
        request.setValue("blussh", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await probeSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            let body = String(decoding: data.prefix(65536), as: UTF8.self)
            return isT3Page(status: http.statusCode,
                            contentType: http.value(forHTTPHeaderField: "Content-Type"), body: body)
        } catch let error as URLError where error.code == .cannotFindHost || error.code == .dnsLookupFailed {
            return nil
        } catch {
            return false
        }
    }

    // MARK: - Output handling

    static func stripANSI(_ text: String) -> String {
        ansi.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    static func redact(_ text: String?) -> String {
        let text = text ?? ""
        return token.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: "$1<redacted>")
    }

    /// The `Pairing URL:` line of `t3 pair`, pointed at the host's MagicDNS name.
    ///
    /// Without --tailscale, t3 prints the server's own (loopback or LAN) URL;
    /// clients reach it through Tailscale Serve on https://<magicdns>/ instead.
    static func extractPairingURL(_ output: String?, magicDNS: String?) -> String? {
        let clean = stripANSI(output ?? "")
        guard let match = pairingURL.firstMatch(in: clean, range: NSRange(clean.startIndex..., in: clean)),
              let range = Range(match.range(at: 1), in: clean),
              var url = URLComponents(string: String(clean[range])),
              let scheme = url.scheme, scheme.hasPrefix("http"),
              let host = url.host, !host.isEmpty else { return nil }
        if let magicDNS = magicDNS, !magicDNS.isEmpty, host.lowercased() != magicDNS.lowercased() {
            url.scheme = "https"
            url.user = nil
            url.password = nil
            url.port = nil
            url.host = magicDNS
        }
        return url.string
    }

    /// The pairing code inside a pairing URL's fragment (`#token=<code>`).
    static func pairingCode(fromURL url: String) -> String? {
        guard let fragment = URLComponents(string: url)?.percentEncodedFragment,
              let range = fragment.range(of: "token=") else { return nil }
        let code = String(fragment[range.upperBound...])
        return code.isEmpty ? nil : code
    }

    /// Last non-empty line of a process's output, redacted, for error messages.
    static func lastLine(_ result: ProcessResult) -> String {
        let text = redact(stripANSI(result.stderr + result.stdout))
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let last = lines.last else { return "exit \(result.status)" }
        return String(last.prefix(200))
    }

    // MARK: - Minting

    /// Shell script that mints the pairing link on the T3 host.
    ///
    /// Non-interactive ssh often lacks t3 on PATH, so look for it in the places
    /// T3 Code installs it. Kept free of backslashes so it survives being quoted
    /// for any remote login shell, fish included. Identical to `t3_pair_script`.
    static func pairScript(label: String) -> String {
        """
        label=\(shellQuote(label))
        ttl=\(pairTTL)
        t3=
        if command -v t3 >/dev/null 2>&1; then
          t3=t3
        elif [ -x "$HOME/.local/bin/t3" ]; then
          t3="$HOME/.local/bin/t3"
        else
          v=$(grep -o '"activeVersion"[^,}]*' "$HOME/.t3/runtime/service-state.json" 2>/dev/null | cut -d'"' -f4)
          if [ -n "$v" ] && [ -x "$HOME/.t3/runtime/versions/$v/t3" ]; then
            t3="$HOME/.t3/runtime/versions/$v/t3"
          fi
        fi
        pair() {
          if [ -n "$t3" ]; then
            "$t3" pair "$@" </dev/null
          elif command -v npx >/dev/null 2>&1; then
            npx -y t3 pair "$@" </dev/null
          else
            echo "t3 not found on $(hostname)" >&2
            return 127
          fi
        }
        pair --tailscale --ttl "$ttl" --label "$label"
        rc=$?
        if [ $rc -ne 0 ] && [ $rc -ne 127 ]; then
          pair --ttl "$ttl" --label "$label"
          rc=$?
        fi
        exit $rc

        """
    }

    /// The command that runs the pairing script: over ssh on `target`, or locally when nil.
    static func pairCommand(target: String?, label: String) -> [String] {
        let script = pairScript(label: label)
        if let target = target {
            // ServerAlive*: give up on a host that drops off mid-run in ~10 s
            return ["/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=5",
                    "-o", "ServerAliveCountMax=2", target, "bash -lc " + shellQuote(script)]
        }
        return ["/bin/bash", "-lc", script]
    }

    typealias Runner = (_ command: [String], _ timeout: TimeInterval) async throws -> ProcessResult

    /// Run `t3 pair` on `target` (ssh destination, nil = this machine) and
    /// return the pairing URL. The output, token included, only lives in memory.
    static func mintPairingURL(target: String?, magicDNS: String?, label: String,
                               run: Runner = runProcess) async -> Result<String, T3Error> {
        let command = pairCommand(target: target, label: label)
        let place = target ?? "this machine"
        let result: ProcessResult
        do {
            result = try await run(command, pairTimeout)
        } catch ProcessRunError.timedOut {
            return .failure(T3Error("t3 pair on \(place) timed out after \(Int(pairTimeout)) s"))
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(T3Error("can't run \((command[0] as NSString).lastPathComponent): \(error.localizedDescription)"))
        }
        guard let url = extractPairingURL(result.stdout, magicDNS: magicDNS) else {
            return .failure(T3Error("no pairing link from \(place): \(lastLine(result))"))
        }
        return .success(url)
    }

    /// Mint as for the link, but return just the pairing code, to hand to another
    /// machine (`t3 environment link … --pairing-code`). Only lives in memory.
    static func mintPairingCode(target: String?, magicDNS: String?, label: String,
                                run: Runner = runProcess) async -> Result<String, T3Error> {
        switch await mintPairingURL(target: target, magicDNS: magicDNS, label: label, run: run) {
        case .failure(let error): return .failure(error)
        case .success(let url):
            guard let code = pairingCode(fromURL: url) else {
                return .failure(T3Error("no pairing code in the link from \(target ?? "this machine")"))
            }
            return .success(code)
        }
    }

    // MARK: - Server to server link

    /// Access levels for `t3 environment link --access`, full access first (the default choice).
    static let linkAccessLevels: [(level: String, label: String)] = [
        ("full-access", "Full access"),
        ("auto", "Auto"),
        ("auto-accept-edits", "Auto-accept edits"),
        ("approval-required", "Supervised (approval-required)"),
        ("read-only", "Read-only"),
    ]

    /// This machine's t3, looked up like the pairing script does on the host.
    /// GUI apps don't get Homebrew or ~/.local/bin on PATH, so look there explicitly.
    static func findLocalT3(home: String = NSHomeDirectory()) -> String? {
        let fm = FileManager.default
        for dir in searchPath(home: home) {
            let candidate = (dir as NSString).appendingPathComponent("t3")
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        let statePath = (home as NSString).appendingPathComponent(".t3/runtime/service-state.json")
        if let data = fm.contents(atPath: statePath),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let version = json["activeVersion"] as? String, !version.isEmpty {
            let binary = (home as NSString).appendingPathComponent(".t3/runtime/versions/\(version)/t3")
            if fm.isExecutableFile(atPath: binary) { return binary }
        }
        return nil
    }

    /// Link the host's T3 Code server to this machine's, so agents here can work
    /// there: mint a pairing code on the host over ssh and redeem it here with
    /// `t3 environment link`. The returned message never contains the token.
    static func link(target: String?, magicDNS: String, label: String, access: String,
                     localT3: String? = nil, run: Runner = runProcess) async -> Result<String, T3Error> {
        guard linkAccessLevels.contains(where: { $0.level == access }) else {
            return .failure(T3Error("unknown access level \(access)"))
        }
        guard let binary = localT3 ?? findLocalT3() else {
            return .failure(T3Error("t3 isn't installed on this machine"))
        }
        let url: String
        switch await mintPairingURL(target: target, magicDNS: magicDNS, label: label, run: run) {
        case .failure(let error): return .failure(error)
        case .success(let minted): url = minted
        }
        guard let code = pairingCode(fromURL: url) else {
            return .failure(T3Error("no pairing code in the link from \(target ?? "this machine")"))
        }
        // The one-time code is in argv for the second or so this takes: t3 has no
        // stdin option for it, and only this user's processes can see it
        let command = [binary, "environment", "link", "https://\(magicDNS)",
                       "--pairing-code", code, "--access", access]
        do {
            var result = try await run(command, pairTimeout)
            if result.status != 0 {
                result.stdout = result.stdout.replacingOccurrences(of: code, with: "<redacted>")
                result.stderr = result.stderr.replacingOccurrences(of: code, with: "<redacted>")
                return .failure(T3Error("t3 environment link failed: \(lastLine(result))"))
            }
        } catch ProcessRunError.timedOut {
            return .failure(T3Error("t3 environment link timed out"))
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(T3Error("can't run t3: \(error.localizedDescription)"))
        }
        return .success("Linked \(magicDNS) to T3 here (\(access))")
    }

    // MARK: - Monitor

    /// Best resource monitor the host has. Run through `sh -lc` so the user's
    /// login shell (fish, zsh…) doesn't matter and ~/.profile PATH additions apply.
    static let monitorScript = "if command -v btop >/dev/null 2>&1; then exec btop; "
        + "elif command -v htop >/dev/null 2>&1; then exec htop; "
        + "else exec top; fi"

    static func monitorCommand(target: String) -> [String] {
        ["ssh", "-t", target, "sh -lc " + shellQuote(monitorScript)]
    }

    // MARK: - Shell

    /// POSIX shell quoting, same output as Python's `shlex.quote`.
    static func shellQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn: "@%+=:,./-_")
            .union(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"))
        if s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Directories searched for local binaries: PATH plus the ones GUI apps lack.
    static func searchPath(home: String = NSHomeDirectory()) -> [String] {
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let extra = [(home as NSString).appendingPathComponent(".local/bin"),
                     "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        var seen = Set<String>()
        return (inherited + extra).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Short hostname of this machine, the label `t3 pair` records for the connection.
    static func localShortHostname() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let name = gethostname(&buffer, buffer.count) == 0 ? String(cString: buffer) : ProcessInfo.processInfo.hostName
        return name.components(separatedBy: ".").first ?? name
    }
}

struct T3Error: Error {
    let message: String
    /// The user cancelled the run (not a failure worth a notification)
    var isCancelled = false
    init(_ message: String) { self.message = message }

    static var cancelled: T3Error {
        var error = T3Error("Cancelled")
        error.isCancelled = true
        return error
    }
}

// MARK: - Processes

struct ProcessResult {
    var status: Int32
    var stdout: String
    var stderr: String
}

enum ProcessRunError: Error {
    case timedOut
}

/// Runs `command` (absolute executable first) with stdin closed, collecting
/// output in memory. Kills it after `timeout`, or when the calling task is
/// cancelled (throwing `CancellationError`), children included. PATH gets
/// Homebrew and ~/.local/bin, which processes started by a GUI app otherwise lack.
func runProcess(_ command: [String], timeout: TimeInterval) async throws -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command[0])
    process.arguments = Array(command.dropFirst())
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = T3.searchPath().joined(separator: ":")
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let stdout = Pipe(), stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    let lock = NSLock()
    var stop: ProcessStop?
    /// Records why the process is being stopped (first reason wins) and kills it
    func stopProcess(_ reason: ProcessStop) {
        lock.lock()
        if stop == nil { stop = reason }
        lock.unlock()
        if process.isRunning { terminateTree(process.processIdentifier) }
    }

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            let group = DispatchGroup()
            var out = Data(), err = Data()

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            // Cancelled before the process started: the handler found nothing to kill
            if Task.isCancelled { stopProcess(.cancelled) }
            // Drain both pipes concurrently so a chatty process can't fill one and block
            for (pipe, isOut) in [(stdout, true), (stderr, false)] {
                group.enter()
                DispatchQueue.global().async {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    lock.lock()
                    if isOut { out = data } else { err = data }
                    lock.unlock()
                    group.leave()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { stopProcess(.timedOut) }
            }
            DispatchQueue.global().async {
                process.waitUntilExit()
                // A killed process's children may still hold the pipes open; don't wait on them forever
                _ = group.wait(timeout: .now() + 2)
                lock.lock(); let reason = stop; lock.unlock()
                switch reason {
                case .timedOut: continuation.resume(throwing: ProcessRunError.timedOut)
                case .cancelled: continuation.resume(throwing: CancellationError())
                case nil:
                    lock.lock()
                    let result = ProcessResult(status: process.terminationStatus,
                                               stdout: String(decoding: out, as: UTF8.self),
                                               stderr: String(decoding: err, as: UTF8.self))
                    lock.unlock()
                    continuation.resume(returning: result)
                }
            }
        }
    } onCancel: {
        stopProcess(.cancelled)
    }
}

private enum ProcessStop {
    case timedOut, cancelled
}

/// SIGTERM `pid` and all its descendants, collected before anything dies (an
/// orphan is reparented to launchd and can't be found from here any more).
/// `bash -lc` runs t3/npx as children, and ssh may run a ProxyCommand.
func terminateTree(_ pid: pid_t) {
    var pids = [pid]
    var index = 0
    while index < pids.count {
        let parent = pids[index]
        index += 1
        let count = proc_listchildpids(parent, nil, 0)
        guard count > 0 else { continue }
        var children = [pid_t](repeating: 0, count: Int(count) + 8)
        let found = proc_listchildpids(parent, &children, Int32(children.count * MemoryLayout<pid_t>.size))
        // Returns the number of pids (newer macOS) or bytes; either way the tail is zeros
        pids += children.prefix(Int(max(found, 0))).filter { $0 > 0 && !pids.contains($0) }
    }
    // Children first, so a parent can't respawn or report before they're gone
    for child in pids.reversed() { kill(child, SIGTERM) }
}
