import SwiftUI
import Foundation
import Combine
import AppKit
import Darwin
import Security

struct Command: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var phrase: String = ""
    var shortcut: String = ""
}

@MainActor final class BridgeModel: ObservableObject {
    @Published var commands: [Command] = [] { didSet { save() } }
    @Published var shortcuts: [String] = []
    @Published var log: String = "Готово"
    @Published var serverRunning: Bool = false
    @Published var stationHost: String = "" { didSet { saveStationSettings() } }
    @Published var stationEnabled: Bool = false { didSet { saveStationSettings() } }
    @Published private(set) var stationRunning: Bool = false
    let port: UInt16 = 8765
    let stationPort: UInt16 = 8767
    private var server: LocalBridgeServer?
    private var stationServer: LocalBridgeServer?

    private var applicationSupportFolder: URL {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mini2MacBridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    private var storage: URL { applicationSupportFolder.appendingPathComponent("commands.json") }
    private var stationSettingsStorage: URL { applicationSupportFolder.appendingPathComponent("station.json") }

    private struct StationSettings: Codable {
        var host: String
        var enabled: Bool
    }

    init() {
        if let data = try? Data(contentsOf: storage), let saved = try? JSONDecoder().decode([Command].self, from: data) {
            commands = saved
        }
        if let data = try? Data(contentsOf: stationSettingsStorage),
           let saved = try? JSONDecoder().decode(StationSettings.self, from: data) {
            stationHost = saved.host
            stationEnabled = saved.enabled
        }
        refreshShortcuts()
        startServer()
        if stationEnabled { startStationLink() }
    }
    func save() {
        guard let data = try? JSONEncoder().encode(commands) else { return }
        try? data.write(to: storage, options: .atomic)
    }
    func saveStationSettings() {
        let settings = StationSettings(host: stationHost, enabled: stationEnabled)
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: stationSettingsStorage, options: .atomic)
    }
    func refreshShortcuts() {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts"); p.arguments = ["list"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
            do {
                try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let values = String(data: data, encoding: .utf8)?.split(separator: "\n").map(String.init) ?? []
                DispatchQueue.main.async { self.shortcuts = values; if p.terminationStatus != 0 { self.log = "Не удалось получить список Быстрых команд" } }
            } catch { DispatchQueue.main.async { self.log = "Ошибка: \(error.localizedDescription)" } }
        }
    }
    func run(_ cmd: Command) {
        guard shortcuts.contains(cmd.shortcut) else { log = "Быстрая команда не найдена: \(cmd.shortcut)"; return }
        let shortcutName = cmd.shortcut
        log = "Запуск: \(shortcutName)"
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts"); p.arguments = ["run", shortcutName]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            do {
                try p.run(); p.waitUntilExit()
                DispatchQueue.main.async { self.log = p.terminationStatus == 0 ? "Выполнено: \(shortcutName)" : "Ошибка запуска (код \(p.terminationStatus))" }
            } catch { DispatchQueue.main.async { self.log = "Ошибка: \(error.localizedDescription)" } }
        }
    }
    func startServer() {
        guard server == nil else { return }
        let server = LocalBridgeServer(port: port) { [weak self] id in
            Task { @MainActor in
                guard let self, let command = self.commands.first(where: { $0.id.uuidString.lowercased() == id.lowercased() }) else { return }
                self.run(command)
            }
        }
        do { try server.start(); self.server = server; serverRunning = true }
        catch { log = "Сервер не запустился: \(error.localizedDescription)" }
    }

    func startStationLink() {
        guard stationServer == nil else {
            synchronizeStationPhrases()
            return
        }
        let host = stationHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidIPv4Address(host) else {
            stationEnabled = false
            stationRunning = false
            log = "Укажи IPv4-адрес Яндекс.Станции"
            return
        }
        do {
            let token = try StationKeychain.token()
            let server = LocalBridgeServer(
                port: stationPort,
                access: .protectedLAN(allowedPeerIPv4: host, bearerToken: token),
                allowedMethods: ["GET"]
            ) { [weak self] id in
                Task { @MainActor in
                    guard let self, let command = self.commands.first(where: { $0.id.uuidString.lowercased() == id.lowercased() }) else { return }
                    self.run(command)
                }
            }
            try server.start()
            stationServer = server
            stationRunning = true
            stationEnabled = true
            log = "Подключаю локальный голосовой контроллер…"
            deployStationController(host: host, token: token)
        } catch {
            stationEnabled = false
            stationRunning = false
            log = "Станция не подключена: \(error.localizedDescription)"
        }
    }

    func stopStationLink() {
        stationServer?.stop()
        stationServer = nil
        stationRunning = false
        stationEnabled = false
        let host = stationHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidIPv4Address(host) else {
            log = "Локальный голосовой контроллер отключён"
            return
        }
        DispatchQueue.global(qos: .utility).async {
            _ = try? Self.runADB(host: host, arguments: ["shell", "sh", "\(Self.stationDirectory)/stop.sh"])
            DispatchQueue.main.async { self.log = "Локальный голосовой контроллер отключён" }
        }
    }

    func synchronizeStationPhrases() {
        let host = stationHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard stationRunning, isValidIPv4Address(host) else {
            log = "Сначала включи подключение к Станции"
            return
        }
        do {
            let token = try StationKeychain.token()
            log = "Синхронизирую фразы со Станцией…"
            deployStationController(host: host, token: token)
        } catch {
            log = "Не удалось подготовить ключ Станции: \(error.localizedDescription)"
        }
    }

    private func deployStationController(host: String, token: String) {
        let commands = commands.flatMap { command -> [String] in
            let phrase = command.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty, !command.shortcut.isEmpty,
                  !phrase.contains("\n"), !phrase.contains("\r"), !phrase.contains("\t") else { return [] }
            let sentenceCase = phrase.prefix(1).uppercased() + phrase.dropFirst().lowercased()
            let variants = Set([phrase, phrase.lowercased(), sentenceCase])
            return variants.map { "\($0)\t\(command.id.uuidString)" }
        }.joined(separator: "\n") + "\n"
        let macHost = LocalNetwork.preferredIPv4Address() ?? ""
        guard isValidIPv4Address(macHost) else {
            log = "Не удалось определить IP этого Mac"
            return
        }

        let config = "MAC_HOST='\(macHost)'\nMAC_PORT='\(stationPort)'\nAUTH_TOKEN='\(token)'\n"
        let temporaryFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mini2MacBridge-\(UUID().uuidString)", isDirectory: true)
        let watcherURL = temporaryFolder.appendingPathComponent("watcher.sh")
        let configURL = temporaryFolder.appendingPathComponent("controller.conf")
        let commandsURL = temporaryFolder.appendingPathComponent("commands.tsv")
        let restartURL = temporaryFolder.appendingPathComponent("restart.sh")
        let stopURL = temporaryFolder.appendingPathComponent("stop.sh")

        DispatchQueue.global(qos: .userInitiated).async {
            defer { try? FileManager.default.removeItem(at: temporaryFolder) }
            do {
                try FileManager.default.createDirectory(at: temporaryFolder, withIntermediateDirectories: true)
                try Data(Self.stationWatcher.utf8).write(to: watcherURL, options: .atomic)
                try Data(config.utf8).write(to: configURL, options: .atomic)
                try Data(commands.utf8).write(to: commandsURL, options: .atomic)
                try Data(Self.stationStartScript.utf8).write(to: restartURL, options: .atomic)
                try Data(Self.stationStopScript.utf8).write(to: stopURL, options: .atomic)

                _ = try Self.runADB(host: host, arguments: ["shell", "mkdir", "-p", Self.stationDirectory])
                _ = try Self.runADB(host: host, arguments: ["push", watcherURL.path, "\(Self.stationDirectory)/watcher.sh"])
                _ = try Self.runADB(host: host, arguments: ["push", configURL.path, "\(Self.stationDirectory)/controller.conf"])
                _ = try Self.runADB(host: host, arguments: ["push", commandsURL.path, "\(Self.stationDirectory)/commands.tsv"])
                _ = try Self.runADB(host: host, arguments: ["push", restartURL.path, "\(Self.stationDirectory)/restart.sh"])
                _ = try Self.runADB(host: host, arguments: ["push", stopURL.path, "\(Self.stationDirectory)/stop.sh"])
                _ = try Self.runADB(host: host, arguments: ["shell", "chmod", "700", "\(Self.stationDirectory)/watcher.sh", "\(Self.stationDirectory)/restart.sh", "\(Self.stationDirectory)/stop.sh"])
                _ = try Self.runADB(host: host, arguments: ["shell", "chmod", "600", "\(Self.stationDirectory)/controller.conf", "\(Self.stationDirectory)/commands.tsv"])
                _ = try Self.runADB(host: host, arguments: ["shell", "sh", "\(Self.stationDirectory)/restart.sh"])
                DispatchQueue.main.async { self.log = "Станция слушает настроенные фразы" }
            } catch {
                DispatchQueue.main.async { self.log = "Не удалось настроить Станцию: \(error.localizedDescription)" }
            }
        }
    }

    private nonisolated static let stationDirectory = "/data/opt/mini2mac-voice"
    private nonisolated static let stationStartScript = """
    base=/data/opt/mini2mac-voice
    if [ -x /sbin/start-stop-daemon ]; then
      /sbin/start-stop-daemon -K -p \"$base/watcher.pid\" -o 2>/dev/null || true
      rm -f \"$base/watcher.pid\"
      /sbin/start-stop-daemon -S -b -m -p \"$base/watcher.pid\" -x \"$base/watcher.sh\"
    else
      if [ -s \"$base/watcher.pid\" ]; then
        previous_pid=$(cat \"$base/watcher.pid\" 2>/dev/null || true)
        [ -n \"$previous_pid\" ] && kill \"$previous_pid\" 2>/dev/null || true
      fi
      /usr/bin/setsid \"$base/watcher.sh\" </dev/null >\"$base/watcher.log\" 2>&1 &
      echo $! >\"$base/watcher.pid\"
    fi
    """
    private nonisolated static let stationStopScript = """
    base=/data/opt/mini2mac-voice
    if [ -x /sbin/start-stop-daemon ]; then
      /sbin/start-stop-daemon -K -p \"$base/watcher.pid\" -o 2>/dev/null || true
    elif [ -s \"$base/watcher.pid\" ]; then
      previous_pid=$(cat \"$base/watcher.pid\" 2>/dev/null || true)
      [ -n \"$previous_pid\" ] && kill \"$previous_pid\" 2>/dev/null || true
    fi
    rm -f \"$base/watcher.pid\"
    """
    private nonisolated static let stationWatcher = #"""
    #!/bin/sh
    set -u

    base=/data/opt/mini2mac-voice
    . "$base/controller.conf"
    log_file=/data/quasar/daemons_logs/maind.log
    commands_file="$base/commands.tsv"
    last_phrase=''
    last_time=0

    pipe="/tmp/mini2mac-voice-watcher-$$"
    tail_pid=''
    cli_pid=''
    control_pipe="$pipe-control"
    cleanup() {
      [ -n "$tail_pid" ] && kill "$tail_pid" 2>/dev/null || true
      [ -n "$cli_pid" ] && kill "$cli_pid" 2>/dev/null || true
      exec 3>&-
      rm -f "$pipe" "$control_pipe"
    }
    trap 'cleanup; exit 0' INT TERM HUP
    trap cleanup EXIT
    rm -f "$pipe"
    mkfifo "$pipe" "$control_pipe" || exit 1
    exec 3<>"$control_pipe"
    LD_LIBRARY_PATH=/system/vendor/quasar/libs /system/vendor/quasar/maind --cli <"$control_pipe" >/dev/null 2>&1 &
    cli_pid=$!
    # BusyBox tail only supports whole-second polling. Read new bytes every 100ms.
    follow_log() {
      set -- $(ls -lin --color=never "$log_file" 2>/dev/null)
      previous_inode=${1:-0}
      offset=${6:-0}
      while :; do
        usleep 100000
        metadata=$(ls -lin --color=never "$log_file" 2>/dev/null) || continue
        set -- $metadata
        inode=$1; size=$6
        if [ "$inode" != "$previous_inode" ] || [ "$size" -lt "$offset" ]; then
          offset=0
          previous_inode=$inode
        fi
        if [ "$size" -gt "$offset" ]; then
          dd if="$log_file" bs=1 skip="$offset" count="$((size - offset))" 2>/dev/null
          offset=$size
        fi
      done
    }
    follow_log >"$pipe" &
    tail_pid=$!

    while IFS= read -r line; do
      case "$line" in
        *"recognizedPhrase='"*"'"*) ;;
        *) continue ;;
      esac
      phrase=$(printf '%s\n' "$line" | sed -n "s/.*recognizedPhrase='\([^']*\)'.*/\1/p")
      [ -n "$phrase" ] || continue
      now=$(date +%s 2>/dev/null || echo 0)
      if [ "$phrase" = "$last_phrase" ] && [ $((now - last_time)) -lt 3 ]; then
        continue
      fi
      last_phrase="$phrase"
      last_time="$now"
      while IFS="$(printf '\t')" read -r trigger command_id; do
        [ "$phrase" = "$trigger" ] || continue
        # Cancel Alice's current response only for a configured Mac phrase.
        if kill -0 "$cli_pid" 2>/dev/null; then
          printf 'c' >&3
        fi
        /usr/bin/wget -q -T 3 -O /dev/null \
          --header "Authorization: Bearer $AUTH_TOKEN" \
          "http://$MAC_HOST:$MAC_PORT/run/$command_id" || true
        break
      done < "$commands_file"
    done < "$pipe"
    """#

    private nonisolated static func runADB(host: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/adb")
        process.arguments = ["-s", "\(host):5555"] + arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorText = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "Mini2MacBridge.ADB", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errorText.isEmpty ? text : errorText])
        }
        return text
    }

    private func isValidIPv4Address(_ value: String) -> Bool {
        var address = in_addr()
        return value.withCString { inet_pton(AF_INET, $0, &address) } == 1
    }
}

enum BridgeAccess {
    case loopbackOnly
    case protectedLAN(allowedPeerIPv4: String, bearerToken: String)
}

// Local-only endpoint: POST http://127.0.0.1:8765/run/<UUID>
// No arbitrary script execution: UUID must match a configured Shortcut.
// This endpoint must NEVER be forwarded to the public Internet without authentication.
// Optional LAN endpoints are separately enabled, IP-restricted, and token-protected.
final class LocalBridgeServer {
    private let port: UInt16
    private let access: BridgeAccess
    private let allowedMethods: Set<String>
    private let onCommand: (String) -> Void
    private let queue = DispatchQueue(label: "Mini2MacBridge.LocalServer")
    private var listenerFD: Int32 = -1
    private var listenerSource: DispatchSourceRead?
    private var clientSources: [Int32: DispatchSourceRead] = [:]
    private var requestBuffers: [Int32: Data] = [:]

    init(port: UInt16, access: BridgeAccess = .loopbackOnly, allowedMethods: Set<String> = ["POST"], onCommand: @escaping (String) -> Void) {
        self.port = port
        self.access = access
        self.allowedMethods = allowedMethods
        self.onCommand = onCommand
    }

    deinit { stop() }

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw systemError() }

        var reuseAddress: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, socklen_t(MemoryLayout.size(ofValue: reuseAddress))) == 0 else {
            Darwin.close(fd)
            throw systemError()
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        let bindAddress: in_addr_t
        switch access {
        case .loopbackOnly:
            bindAddress = in_addr_t(INADDR_LOOPBACK)
        case .protectedLAN:
            bindAddress = in_addr_t(INADDR_ANY)
        }
        address.sin_addr = in_addr(s_addr: bindAddress.bigEndian)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(fd)
            throw systemError()
        }
        guard listen(fd, SOMAXCONN) == 0 else {
            Darwin.close(fd)
            throw systemError()
        }

        listenerFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.setCancelHandler { Darwin.close(fd) }
        listenerSource = source
        source.resume()
    }

    func stop() {
        listenerSource?.cancel()
        listenerSource = nil
        listenerFD = -1
        for source in clientSources.values { source.cancel() }
        clientSources.removeAll()
        requestBuffers.removeAll()
    }

    private func acceptConnection() {
        var peerAddress = sockaddr_storage()
        var peerAddressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let clientFD = withUnsafeMutablePointer(to: &peerAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.accept(listenerFD, $0, &peerAddressLength)
            }
        }
        guard clientFD >= 0 else { return }
        guard peerIsAllowed(peerAddress) else {
            Darwin.close(clientFD)
            return
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
        source.setEventHandler { [weak self] in self?.readRequest(from: clientFD) }
        source.setCancelHandler { Darwin.close(clientFD) }
        clientSources[clientFD] = source
        source.resume()
    }

    private func readRequest(from clientFD: Int32) {
        var bytes = [UInt8](repeating: 0, count: 2_048)
        let count = Darwin.recv(clientFD, &bytes, bytes.count, 0)
        guard count > 0 else { close(clientFD); return }

        requestBuffers[clientFD, default: Data()].append(contentsOf: bytes.prefix(Int(count)))
        guard let requestData = requestBuffers[clientFD] else { close(clientFD); return }
        guard requestData.count <= 2_048 else {
            respond(status: "413 Payload Too Large", body: "Payload Too Large", to: clientFD)
            return
        }
        guard requestData.range(of: Data("\r\n\r\n".utf8)) != nil else { return }

        let request = String(data: requestData, encoding: .utf8) ?? ""
        guard requestIsAuthorized(request) else {
            respond(status: "401 Unauthorized", body: "Unauthorized", to: clientFD)
            return
        }
        let firstLine = request.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ").map(String.init)
        if parts.count >= 2, allowedMethods.contains(parts[0]), parts[1].hasPrefix("/run/"),
           let uuid = UUID(uuidString: String(parts[1].dropFirst(5))) {
            onCommand(uuid.uuidString)
            respond(status: "202 Accepted", body: "Queued", to: clientFD)
        } else {
            respond(status: "404 Not Found", body: "Not Found", to: clientFD)
        }
    }

    private func respond(status: String, body: String, to clientFD: Int32) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        _ = response.withCString { Darwin.send(clientFD, $0, strlen($0), 0) }
        close(clientFD)
    }

    private func close(_ clientFD: Int32) {
        requestBuffers.removeValue(forKey: clientFD)
        clientSources.removeValue(forKey: clientFD)?.cancel()
    }

    private func peerIsAllowed(_ peerAddress: sockaddr_storage) -> Bool {
        guard case let .protectedLAN(allowedPeerIPv4, _) = access else { return true }
        guard peerAddress.ss_family == sa_family_t(AF_INET) else { return false }

        var copy = peerAddress
        return withUnsafePointer(to: &copy) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                var address = pointer.pointee.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else { return false }
                return String(cString: buffer) == allowedPeerIPv4
            }
        }
    }

    private func requestIsAuthorized(_ request: String) -> Bool {
        guard case let .protectedLAN(_, bearerToken) = access else { return true }
        let expected = "Bearer \(bearerToken)"
        for line in request.components(separatedBy: "\r\n").dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator]
            guard name.caseInsensitiveCompare("Authorization") == .orderedSame else { continue }
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            return value == expected
        }
        return false
    }

    private func systemError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

enum StationKeychain {
    private static let service = "Mini2MacBridge"
    private static let account = "station-bearer-token"

    static func token() throws -> String {
        if let existing = read() { return existing }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw KeychainError.unavailable
        }
        let generated = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(generated.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unavailable }
        return generated
    }

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    enum KeychainError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Не удалось сохранить ключ Станции в Связке ключей macOS" }
    }
}

enum LocalNetwork {
    static func preferredIPv4Address() -> String? {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return nil }
        defer { freeifaddrs(firstAddress) }

        var values: [(interface: String, address: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let current = cursor {
            let interface = current.pointee
            defer { cursor = interface.ifa_next }
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.ifa_name)
            guard name != "lo0" else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let value = String(cString: hostname)
            guard isPrivateIPv4(value) else { continue }
            values.append((name, value))
        }

        return values.sorted {
            let firstPriority = $0.interface == "en0" ? 0 : 1
            let secondPriority = $1.interface == "en0" ? 0 : 1
            return firstPriority == secondPriority ? $0.interface < $1.interface : firstPriority < secondPriority
        }.first?.address
    }

    private static func isPrivateIPv4(_ value: String) -> Bool {
        if value.hasPrefix("10.") || value.hasPrefix("192.168.") { return true }
        let parts = value.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 172 && (16...31).contains(parts[1])
    }
}

struct StationSetupView: View {
    @ObservedObject var model: BridgeModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Локальное подключение") {
                    TextField("IPv4 Яндекс.Станции", text: $model.stationHost)
                    Text("Укажи IP Яндекс.Станции. Доступ к Mac получит только этот адрес; приложение само установит контроллер через уже включённый ADB.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if model.stationRunning {
                        Label("Локальный голосовой контроллер включён", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                        Button("Синхронизировать фразы") { model.synchronizeStationPhrases() }
                        Button("Отключить контроллер", role: .destructive) { model.stopStationLink() }
                    } else {
                        Button("Включить локальное управление") { model.startStationLink() }
                    }
                }

                Section("Как пользоваться") {
                    Text("Заполни в каждой команде фразу по-русски, например «Открой Телеграм», затем синхронизируй. Говори: «Алиса, открой Телеграм».")
                        .font(.caption)
                    Text("Станция считывает только уже распознанные Алисой фразы из своего локального журнала; ключ остаётся в домашней сети. Распознавание речи по-прежнему выполняет Алиса через сервисы Яндекса.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Безопасность") {
                    Text("Mac принимает только авторизованные запросы с IP этой Станции на порту 8767. Не открывай этот порт на роутере и не добавляй его в туннели.")
                        .font(.caption)
                }
            }
            .navigationTitle("Яндекс.Станция")
            .toolbar { Button("Готово") { dismiss() } }
        }
        .frame(width: 560, height: 450)
    }
}

struct ContentView: View {
    @StateObject private var model = BridgeModel()
    @State private var selected: UUID?
    @State private var showingStationSetup = false
    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                ForEach(model.commands) { cmd in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(cmd.phrase.isEmpty ? "Новая команда" : cmd.phrase).font(.headline)
                        Text(cmd.shortcut.isEmpty ? "Shortcut не выбран" : cmd.shortcut).font(.caption).foregroundStyle(.secondary)
                    }.tag(cmd.id)
                }
                .onDelete { model.commands.remove(atOffsets: $0) }
            }
            .navigationTitle("Команды Алисы")
            .toolbar {
                Button(action: { let cmd = Command(); model.commands.append(cmd); selected = cmd.id }) { Image(systemName: "plus") }
                Button(action: { model.refreshShortcuts() }) { Image(systemName: "arrow.clockwise") }
            }
        } detail: {
            if let idx = model.commands.firstIndex(where: { $0.id == selected }) {
                Form {
                    TextField("Фраза для сценария Алисы", text: $model.commands[idx].phrase)
                    Picker("Быстрая команда macOS", selection: $model.commands[idx].shortcut) {
                        Text("Выбрать").tag("")
                        ForEach(model.shortcuts, id: \.self) { name in Text(name).tag(name) }
                    }
                    HStack {
                        Button("Проверить на Mac") { model.run(model.commands[idx]) }
                        Spacer()
                        Button("Копировать локальный URL") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("http://127.0.0.1:\(model.port)/run/\(model.commands[idx].id.uuidString)", forType: .string)
                        }
                    }
                    Text("UUID действия: \(model.commands[idx].id.uuidString)").font(.caption).textSelection(.enabled)
                }
                .padding()
                .navigationTitle("Настройка команды")
            } else {
                VStack(spacing: 18) {
                    ContentUnavailableView("Добавь команду", systemImage: "command", description: Text("Выбери существующий Shortcut и укажи голосовую фразу"))
                    Button("Добавить команду", systemImage: "plus") {
                        let cmd = Command()
                        model.commands.append(cmd)
                        selected = cmd.id
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
        .frame(minWidth: 800, minHeight: 480)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Circle().fill(model.serverRunning ? .green : .red).frame(width: 8, height: 8)
                Text("Локальный мост: 127.0.0.1:\(model.port)")
                Spacer()
                Button("Станция…") { showingStationSetup = true }
                Text(model.log).lineLimit(1)
            }.font(.caption).padding(10).background(.bar)
        }
        .sheet(isPresented: $showingStationSetup) {
            StationSetupView(model: model)
        }
    }
}

@main struct Station2MacApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
