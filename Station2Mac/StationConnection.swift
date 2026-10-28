import Foundation
import Darwin

enum StationTransport: String, Codable, CaseIterable, Sendable {
    case adb
    case ssh

    nonisolated var title: String { self == .adb ? "ADB" : "SSH" }
}

enum StationSSHAuthentication: String, Codable, CaseIterable, Sendable {
    case none
    case key
    case password

    nonisolated var title: String {
        switch self {
        case .none: return "Без пароля"
        case .key: return "SSH-ключ / агент"
        case .password: return "Пароль"
        }
    }
}

struct StationConnection: Sendable {
    let transport: StationTransport
    let host: String
    let user: String
    let port: Int
    let identityFile: String
    let authentication: StationSSHAuthentication
    private let password: String

    nonisolated init(transport: StationTransport, host: String, user: String = "root", port: Int = 22,
                     identityFile: String = "", authentication: StationSSHAuthentication = .key, password: String = "") throws {
        var address = in_addr()
        guard host.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
            throw StationConnectionError("Укажи IPv4-адрес Яндекс.Станции")
        }
        if transport == .ssh {
            let permitted = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
            guard !user.isEmpty, user.unicodeScalars.allSatisfy({ permitted.contains($0) }), !user.hasPrefix("-") else {
                throw StationConnectionError("Укажи корректного пользователя SSH")
            }
            guard (1...65535).contains(port) else {
                throw StationConnectionError("Порт SSH должен быть от 1 до 65535")
            }
            if authentication == .password, password.isEmpty {
                throw StationConnectionError("Введи пароль SSH или выбери режим «Без пароля»")
            }
        }
        self.transport = transport
        self.host = host
        self.user = user
        self.port = port
        self.authentication = authentication
        self.password = password
        self.identityFile = (identityFile as NSString).expandingTildeInPath
        if transport == .ssh, authentication == .key, !self.identityFile.isEmpty,
           !FileManager.default.isReadableFile(atPath: self.identityFile) {
            throw StationConnectionError("Не удалось прочитать выбранный SSH-ключ")
        }
    }

    nonisolated func prepare() throws {
        if transport == .adb {
            let response = try Self.run(executable: adbPath(), arguments: ["connect", "\(host):5555"])
            guard !response.lowercased().contains("failed"), !response.lowercased().contains("cannot connect") else {
                throw StationConnectionError(response.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        _ = try shell(["true"])
    }

    @discardableResult
    nonisolated func shell(_ arguments: [String]) throws -> String {
        if transport == .adb {
            let output = try Self.run(executable: adbPath(), arguments: ["-s", "\(host):5555", "shell", arguments.map(Self.shellQuote).joined(separator: " ")])
            return output.replacingOccurrences(of: "\r\n", with: "\n")
        }
        return try ssh(command: arguments.map(Self.shellQuote).joined(separator: " "))
    }

    nonisolated func upload(_ file: URL, to destination: String) throws {
        if transport == .adb {
            _ = try Self.run(executable: adbPath(), arguments: ["-s", "\(host):5555", "push", file.path, destination])
        } else {
            // Stream the file over SSH: no SFTP server or modern scp is needed on Dropbear.
            _ = try ssh(command: "umask 077; cat > " + Self.shellQuote(destination), inputFile: file)
        }
    }

    private nonisolated func ssh(command: String, inputFile: URL? = nil) throws -> String {
        var arguments = [
            "-T", "-o", "StrictHostKeyChecking=yes",
            "-o", "ConnectTimeout=5", "-o", "ConnectionAttempts=1",
            "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
            "-p", String(port), "-l", user
        ]
        switch authentication {
        case .none:
            arguments += ["-o", "BatchMode=no", "-o", "PreferredAuthentications=none,password",
                          "-o", "PubkeyAuthentication=no", "-o", "KbdInteractiveAuthentication=no",
                          "-o", "PasswordAuthentication=yes", "-o", "NumberOfPasswordPrompts=1"]
        case .key:
            arguments += ["-o", "BatchMode=yes", "-o", "PreferredAuthentications=publickey"]
            if !identityFile.isEmpty { arguments += ["-i", identityFile, "-o", "IdentitiesOnly=yes"] }
        case .password:
            arguments += ["-o", "BatchMode=no", "-o", "PreferredAuthentications=password,keyboard-interactive",
                          "-o", "PubkeyAuthentication=no", "-o", "NumberOfPasswordPrompts=1"]
        }
        arguments += [host, command]
        do {
            return try Self.run(executable: "/usr/bin/ssh", arguments: arguments, inputFile: inputFile,
                                askpassPassword: authentication == .key ? nil : (authentication == .none ? "" : password))
        } catch {
            let hint: String
            switch authentication {
            case .none: hint = "Убедись, что сервер разрешает вход без пароля, или выбери другой способ входа."
            case .key: hint = "Проверь путь к ключу; для ключа с паролем используй ssh-add."
            case .password: hint = "Проверь пользователя и пароль SSH."
            }
            throw StationConnectionError("SSH: \(error.localizedDescription). \(hint) Для первого подключения проверь вход в Терминале: ssh -p \(port) \(user)@\(host) и подтверди ключ хоста.")
        }
    }

    private nonisolated func adbPath() throws -> String {
        for path in ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        throw StationConnectionError("ADB не найден. Установи Android Platform Tools через Homebrew или выбери SSH")
    }

    private nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private nonisolated static func run(executable: String, arguments: [String], inputFile: URL? = nil,
                                       askpassPassword: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let askpassDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("Station2Mac-askpass-\(UUID().uuidString)")
        defer { if askpassPassword != nil { try? FileManager.default.removeItem(at: askpassDirectory) } }
        if let askpassPassword {
            try FileManager.default.createDirectory(at: askpassDirectory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let helper = askpassDirectory.appendingPathComponent("askpass.sh")
            // The temporary helper contains no credentials; the answer is passed only in the child's environment.
            try Data("#!/bin/sh\nprintf '%s\\n' \"$STATION2MAC_SSH_PASSWORD\"\n".utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            var environment = ProcessInfo.processInfo.environment
            environment["SSH_ASKPASS"] = helper.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = "Station2Mac"
            environment["STATION2MAC_SSH_PASSWORD"] = askpassPassword
            process.environment = environment
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let input = try inputFile.map { try FileHandle(forReadingFrom: $0) }
        defer { try? input?.close() }
        process.standardInput = input ?? FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            var message = text.isEmpty ? "Процесс завершился с кодом \(process.terminationStatus)" : String(text.suffix(2_000)).trimmingCharacters(in: .whitespacesAndNewlines)
            if let askpassPassword, !askpassPassword.isEmpty { message = message.replacingOccurrences(of: askpassPassword, with: "••••") }
            throw StationConnectionError(message)
        }
        return text
    }
}

struct StationConnectionError: LocalizedError {
    let message: String
    nonisolated init(_ message: String) { self.message = message }
    nonisolated var errorDescription: String? { message }
}
