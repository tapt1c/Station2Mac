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
    @Published var stationTransport: StationTransport = .adb { didSet { saveStationSettings() } }
    @Published var stationSSHUser: String = "root" { didSet { saveStationSettings() } }
    @Published var stationSSHPort: String = "22" { didSet { saveStationSettings() } }
    @Published var stationSSHIdentity: String = "" { didSet { saveStationSettings() } }
    @Published var stationSSHAuthentication: StationSSHAuthentication = .none { didSet { saveStationSettings() } }
    @Published var stationSSHPassword: String = ""
    @Published private(set) var stationBusy: Bool = false
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
        var transport: StationTransport?
        var sshUser: String?
        var sshPort: String?
        var sshIdentity: String?
        var sshAuthentication: StationSSHAuthentication?
    }

    init() {
        if let data = try? Data(contentsOf: storage), let saved = try? JSONDecoder().decode([Command].self, from: data) {
            commands = saved
        }
        if let data = try? Data(contentsOf: stationSettingsStorage),
           let saved = try? JSONDecoder().decode(StationSettings.self, from: data) {
            stationHost = saved.host
            stationEnabled = saved.enabled
            stationTransport = saved.transport ?? .adb
            stationSSHUser = saved.sshUser ?? "root"
            stationSSHPort = saved.sshPort ?? "22"
            stationSSHIdentity = saved.sshIdentity ?? ""
            stationSSHAuthentication = saved.sshAuthentication ?? .none
        }
        refreshShortcuts()
        startServer()
        if stationEnabled {
            if stationTransport == .ssh, stationSSHAuthentication == .password {
                stationEnabled = false
                log = "Введи пароль SSH в настройках Станции и включи подключение"
            } else {
                startStationLink()
            }
        }
    }
    func save() {
        guard let data = try? JSONEncoder().encode(commands) else { return }
        try? data.write(to: storage, options: .atomic)
    }
    func saveStationSettings() {
        let settings = StationSettings(host: stationHost, enabled: stationEnabled, transport: stationTransport,
                                       sshUser: stationSSHUser, sshPort: stationSSHPort, sshIdentity: stationSSHIdentity,
                                       sshAuthentication: stationSSHAuthentication)
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
        guard !stationBusy else { return }
        guard stationServer == nil else {
            synchronizeStationPhrases()
            return
        }
        let host = stationHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidIPv4Address(host) else {
            stationEnabled = false
            stationRunning = false
            reportStationError(title: "Некорректный адрес Станции", detail: "Укажи IPv4-адрес Яндекс.Станции")
            return
        }
        do {
            _ = try stationConnection()
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
            reportStationError(title: connectionErrorTitle, detail: error.localizedDescription)
        }
    }

    func stopStationLink() {
        guard !stationBusy else { return }
        stationServer?.stop()
        stationServer = nil
        stationRunning = false
        stationEnabled = false
        let connection: StationConnection
        do { connection = try stationConnection() }
        catch {
            reportStationError(title: "Не удалось остановить контроллер", detail: "Доступ к Mac закрыт. \(error.localizedDescription)")
            return
        }
        stationBusy = true
        DispatchQueue.global(qos: .utility).async {
            do {
                _ = try connection.shell(["sh", "\(Self.stationDirectory)/stop.sh"])
                DispatchQueue.main.async {
                    self.stationBusy = false
                    self.log = "Локальный голосовой контроллер отключён"
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    self.stationBusy = false
                    self.reportStationError(title: "Не удалось остановить контроллер", detail: "Доступ к Mac закрыт, но контроллер на Станции не остановлен.\n\n\(message)")
                }
            }
        }
    }

    func synchronizeStationPhrases() {
        guard !stationBusy else { return }
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
            reportStationError(title: "Не удалось подготовить ключ Станции", detail: error.localizedDescription)
        }
    }

    private func deployStationController(host: String, token: String) {
        let connection: StationConnection
        do { connection = try stationConnection() }
        catch { reportStationError(title: connectionErrorTitle, detail: error.localizedDescription); return }
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
            reportStationError(title: "Нет адреса для подключения", detail: "Не удалось определить IP этого Mac. Проверь подключение к домашней сети.")
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

        stationBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            defer { try? FileManager.default.removeItem(at: temporaryFolder) }
            do {
                try FileManager.default.createDirectory(at: temporaryFolder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try Data(Self.stationWatcher.utf8).write(to: watcherURL, options: .atomic)
                try Data(config.utf8).write(to: configURL, options: .atomic)
                try Data(commands.utf8).write(to: commandsURL, options: .atomic)
                try Data(Self.stationStartScript.utf8).write(to: restartURL, options: .atomic)
                try Data(Self.stationStopScript.utf8).write(to: stopURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: commandsURL.path)

                try connection.prepare()
                _ = try connection.shell(["mkdir", "-p", Self.stationDirectory])
                _ = try connection.shell(["chmod", "700", Self.stationDirectory])
                for file in [watcherURL, configURL, commandsURL, restartURL, stopURL] {
                    try connection.upload(file, to: "\(Self.stationDirectory)/\(file.lastPathComponent)")
                }
                _ = try connection.shell(["chmod", "700", "\(Self.stationDirectory)/watcher.sh", "\(Self.stationDirectory)/restart.sh", "\(Self.stationDirectory)/stop.sh"])
                _ = try connection.shell(["chmod", "600", "\(Self.stationDirectory)/controller.conf", "\(Self.stationDirectory)/commands.tsv"])
                _ = try connection.shell(["sh", "\(Self.stationDirectory)/restart.sh"])
                DispatchQueue.main.async {
                    self.stationBusy = false
                    self.log = "Станция слушает настроенные фразы (\(connection.transport.title))"
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    self.stationBusy = false
                    self.stationServer?.stop()
                    self.stationServer = nil
                    self.stationRunning = false
                    self.stationEnabled = false
                    self.reportStationError(title: self.connectionErrorTitle, detail: message)
                }
            }
        }
    }

    private var connectionErrorTitle: String {
        stationTransport == .ssh ? "Не удалось подключиться по SSH" : "Не удалось подключиться по ADB"
    }

    private func reportStationError(title: String, detail: String) {
        log = "\(title): \(detail)"
        StationErrorPresenter.show(title: title, detail: detail)
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

    private func stationConnection() throws -> StationConnection {
        let port = Int(stationSSHPort.trimmingCharacters(in: .whitespacesAndNewlines))
        if stationTransport == .ssh, port == nil {
            throw StationConnectionError("Укажи числовой порт SSH от 1 до 65535")
        }
        return try StationConnection(
            transport: stationTransport,
            host: stationHost.trimmingCharacters(in: .whitespacesAndNewlines),
            user: stationSSHUser.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port ?? 22,
            identityFile: stationSSHIdentity.trimmingCharacters(in: .whitespacesAndNewlines),
            authentication: stationSSHAuthentication,
            password: stationSSHPassword
        )
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
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "hifispeaker.fill")
                    .font(.system(size: 25))
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Яндекс.Станция").font(.title2.bold())
                    Text("Подключение и голосовое управление Mac")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 16) {
                            VStack(alignment: .leading, spacing: 14) {
                                field("Способ подключения") {
                                    Picker("Способ подключения", selection: $model.stationTransport) {
                                        ForEach(StationTransport.allCases, id: \.rawValue) { transport in
                                            Text(transport.title).tag(transport)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                }
                                field("IP-адрес Станции") {
                                    TextField("Например, 192.168.1.10", text: $model.stationHost)
                                        .accessibilityLabel("IP-адрес Станции")
                                }

                                if model.stationTransport == .ssh {
                                    HStack(alignment: .top, spacing: 14) {
                                        field("Пользователь") {
                                            TextField("root", text: $model.stationSSHUser)
                                                .accessibilityLabel("Пользователь SSH")
                                        }
                                        field("Порт") {
                                            TextField("22", text: $model.stationSSHPort)
                                                .accessibilityLabel("Порт SSH")
                                        }
                                        .frame(width: 105)
                                    }
                                    field("Способ входа") {
                                        Picker("Способ входа", selection: $model.stationSSHAuthentication) {
                                            ForEach(StationSSHAuthentication.allCases, id: \.rawValue) { method in
                                                Text(method.title).tag(method)
                                            }
                                        }
                                        .labelsHidden()
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    if model.stationSSHAuthentication == .key {
                                        field("SSH-ключ · необязательно") {
                                            TextField("~/.ssh/id_ed25519", text: $model.stationSSHIdentity)
                                                .accessibilityLabel("Путь к SSH-ключу")
                                        }
                                    } else if model.stationSSHAuthentication == .password {
                                        field("Пароль SSH") {
                                            SecureField("Пароль пользователя Станции", text: $model.stationSSHPassword)
                                                .accessibilityLabel("Пароль SSH")
                                        }
                                    }
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.stationRunning || model.stationBusy)

                            if model.stationTransport == .ssh {
                                hint(sshHint)
                            }
                            if model.stationRunning && !model.stationBusy {
                                hint("Чтобы изменить подключение, сначала отключи контроллер.")
                            }

                            Divider()
                            connectionStatus
                            HStack(spacing: 10) {
                                if model.stationRunning {
                                    Button("Синхронизировать фразы") { model.synchronizeStationPhrases() }
                                        .buttonStyle(.borderedProminent)
                                    Spacer(minLength: 8)
                                    Button("Отключить", role: .destructive) { model.stopStationLink() }
                                } else {
                                    Button("Подключить Станцию") { model.startStationLink() }
                                        .buttonStyle(.borderedProminent)
                                }
                            }
                            .disabled(model.stationBusy)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label("Подключение", systemImage: "network")
                            .font(.headline)
                    }

                    GroupBox {
                        Text(model.log)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    } label: {
                        Label("Состояние", systemImage: "info.circle")
                            .font(.headline)
                    }

                    DisclosureGroup("Как пользоваться") {
                        VStack(alignment: .leading, spacing: 8) {
                            hint("Добавь команду, выбери Shortcut и укажи фразу, например «Включи Телеграм на Маке». Затем синхронизируй фразы и скажи: «Алиса, включи Телеграм на Маке».")
                            hint("Контроллер читает распознанные фразы из журнала Станции. Распознавание речи выполняет Алиса через сервисы Яндекса.")
                        }
                        .padding(.top, 8)
                    }

                    DisclosureGroup("Доступ и безопасность") {
                        hint("Доступ к Mac получит только указанный IP и только с ключом доступа на порту 8767. Не открывай этот порт на роутере и не добавляй его в туннели.")
                            .padding(.top, 8)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Spacer()
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 600, height: 660)
    }

    @ViewBuilder private var connectionStatus: some View {
        if model.stationBusy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Выполняется операция…").font(.callout)
            }
        } else if model.stationRunning {
            Label("Контроллер подключён", systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.green)
        } else {
            Label("Станция не подключена", systemImage: "circle")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var sshHint: String {
        switch model.stationSSHAuthentication {
        case .none:
            return "Станция должна разрешать вход без пароля. При первом подключении подтверди ключ хоста через Терминал."
        case .key:
            return "Можно использовать стандартный ключ или ssh-agent. Ключ с паролем предварительно загрузи через ssh-add. При первом подключении подтверди ключ хоста в Терминале."
        case .password:
            return "Пароль хранится только до закрытия приложения. При первом подключении подтверди ключ хоста через Терминал."
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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
