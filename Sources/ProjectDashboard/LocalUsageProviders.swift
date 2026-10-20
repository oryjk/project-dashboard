import Foundation
import Security
import LocalAuthentication
import Darwin

/// Direct builds can use local CLI credentials. Store builds report the restriction explicitly.
enum LocalAccountAccess {
    static func check() throws {
        if Bundle.main.object(forInfoDictionaryKey: "LocalAccountUsageEnabled") as? Bool == false {
            throw LocalUsageError.message("App Store 沙盒版无法自动读取本机登录，请使用直接分发版查询 Codex / Claude Code 额度")
        }
    }
}

/// Bounded stdio transport: handles notifications, partial lines, timeouts and child cleanup.
struct CodexRPCClient: Sendable {
    var executable: URL
    var timeout: TimeInterval = 20

    func readRateLimits() throws -> Data {
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        // Finder's environment may lack Homebrew/Node even when we found the CLI.
        var environment = ProcessInfo.processInfo.environment
        let runtimeDirectories = [executable.deletingLastPathComponent().path,
                                  FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
                                  "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        environment["PATH"] = (runtimeDirectories + [environment["PATH"] ?? ""]).joined(separator: ":")
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        // Never expose CLI logs or auth payloads through errors.
        process.standardError = FileHandle.nullDevice
        // A dead CLI must become an error, not terminate the entire menu-bar app.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw LocalUsageError.message("无法初始化 Codex 本机连接，请重试")
        }
        do { try process.run() }
        catch { throw LocalUsageError.message("无法启动本机 Codex，请检查 CLI 安装与执行权限") }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(1)
                while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(10)
            do { try input.fileHandleForWriting.write(contentsOf: data) }
            catch { throw LocalUsageError.message("Codex 进程已退出，请检查 CLI 安装与登录后重试") }
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "project_dashboard", "version": "1.0"]]])
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var pending = Data()
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let newline = pending.firstIndex(of: 10) {
                let line = pending[..<newline]
                pending.removeSubrange(...newline)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = message["id"] as? Int else { continue }
                if message["error"] != nil {
                    throw LocalUsageError.message("Codex 无法读取订阅额度，请确认已用 ChatGPT 账号登录；API Key 登录不提供订阅额度")
                }
                if id == 1 {
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "account/rateLimits/read"])
                } else if id == 2, let result = message["result"] as? [String: Any] {
                    return try JSONSerialization.data(withJSONObject: result)
                }
                continue
            }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let remaining = max(1, Int32(min(250, (deadline - ProcessInfo.processInfo.systemUptime) * 1000)))
            let ready = poll(&descriptor, 1, remaining)
            if ready < 0 { if errno == EINTR { continue }; break }
            if ready == 0 { continue }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(descriptor.fd, &buffer, buffer.count)
            guard count > 0 else { break }
            pending.append(contentsOf: buffer.prefix(count))
            guard pending.count <= 4 * 1024 * 1024 else { throw UsageFetchError.parsing }
        }
        throw LocalUsageError.message("Codex 额度查询超时或连接已关闭，请检查本机登录与网络后重试")
    }
}

struct CodexUsageProvider: UsageProviding {
    let id = UsageProviderID.codex

    func fetchUsage(key: String) async throws -> ProviderUsageSummary {
        try LocalAccountAccess.check()
        return try await Task.detached {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let environment = ProcessInfo.processInfo.environment
            let directories = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
                + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            guard let path = directories.map({ URL(fileURLWithPath: $0).appendingPathComponent("codex") })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
                throw LocalUsageError.message("未找到本机 Codex CLI，请先安装并运行 codex login，使用 ChatGPT 账号登录")
            }
            return try CodexUsageParser.parse(CodexRPCClient(executable: path).readRateLimits())
        }.value
    }
}

struct ClaudeUsageProvider: UsageProviding {
    let id = UsageProviderID.claude
    var tokenReader: @Sendable () throws -> String = { try readLocalToken() }
    var requestData: @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
        try await URLSession.shared.data(for: $0)
    }

    func fetchUsage(key: String) async throws -> ProviderUsageSummary {
        try LocalAccountAccess.check()
        var token = try await Task.detached { try tokenReader() }.value
        for attempt in 0..<2 {
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.timeoutInterval = 15
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("ProjectDashboard/1.0", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await requestData(request)
                guard let response = response as? HTTPURLResponse else { throw UsageFetchError.network }
                switch response.statusCode {
                case 200: return try ClaudeUsageParser.parse(data)
                case 401:
                    // A running Claude CLI may have renewed the login while this request ran.
                    // Read again, without rotating or overwriting the shared refresh token.
                    if attempt == 0 {
                        let renewed = try await Task.detached { try tokenReader() }.value
                        if renewed != token { token = renewed; continue }
                    }
                    throw LocalUsageError.message("Claude 用量查询暂不可用（HTTP 401），本机访问令牌尚未更新，面板将自动重试。可在正常使用的 Claude Code 中执行 /usage 后刷新")
                case 403:
                    throw LocalUsageError.message("Claude 用量查询被拒绝（HTTP 403），请检查当前账号的用量权限及网络限制")
                case 429: throw LocalUsageError.message("Claude 用量接口请求过于频繁，请稍后重试")
                default: throw UsageFetchError.http(response.statusCode)
                }
            } catch is URLError { throw UsageFetchError.network }
        }
        throw UsageFetchError.network
    }

    private static func readLocalToken() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let custom = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let directory = custom.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        // Claude hashes custom config paths into its Keychain service. Use its file fallback
        // for custom directories; never accidentally read the default account instead.
        if custom == nil {
            let context = LAContext()
            context.interactionNotAllowed = true
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "Claude Code-credentials",
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationContext as String: context,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data {
                return try ClaudeLocalCredentials.accessToken(from: data)
            }
            if status != errSecItemNotFound {
                throw LocalUsageError.message("无法读取 Claude Code 钥匙串登录，请在“钥匙串访问”中允许项目面板访问 Claude Code-credentials")
            }
        }
        let file = directory.appendingPathComponent(".credentials.json")
        guard let data = try? Data(contentsOf: file) else {
            throw LocalUsageError.message("未找到可读取的 Claude Code 本机登录，请先运行 claude 并执行 /login；自定义 CLAUDE_CONFIG_DIR 需提供该目录的凭据文件")
        }
        return try ClaudeLocalCredentials.accessToken(from: data)
    }
}
