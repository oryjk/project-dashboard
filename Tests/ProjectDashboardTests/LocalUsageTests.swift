import Foundation
import Testing
@testable import ProjectDashboard

struct LocalUsageParserTests {
    @Test func directBuildMigrationPreservesExistingPreferencesAndCopiesOnlyAppSettings() {
        let suite = "dashboard-migration-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["new-pin"], forKey: "pinnedRepoPaths")
        defaults.set(false, forKey: "usage.glm.useInternational")
        DirectPreferencesMigration.migrate(from: [
            "pinnedRepoPaths": ["old-pin"], "archivedRepoPaths": ["archive"],
            "usage.glm.useInternational": true, "unrelated": "value",
        ], into: defaults)
        #expect(defaults.stringArray(forKey: "pinnedRepoPaths") == ["new-pin"])
        #expect(defaults.stringArray(forKey: "archivedRepoPaths") == ["archive"])
        #expect(defaults.bool(forKey: "usage.glm.useInternational") == false)
        #expect(defaults.object(forKey: "unrelated") == nil)
    }

    @Test func codexUsesNamedBucketsAndActualWindowLengths() throws {
        let data = Data(#"{"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":300}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":28,"windowDurationMins":10080,"resetsAt":1792886946},"secondary":null},"review":{"limitName":"Code review","primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1792880000}}}}"#.utf8)
        let result = try CodexUsageParser.parse(data)
        #expect(result.windows.count == 2)
        #expect(result.windows[0] == UsageWindow(label: "周", usedPercent: 28, resetAt: Date(timeIntervalSince1970: 1792886946)))
        #expect(result.windows[1].label == "Code review · 5 小时")
        #expect(result.windows[1].usedPercent == 12)
    }

    @Test func codexFallsBackToLegacyAndClampsPercent() throws {
        let result = try CodexUsageParser.parse(Data(#"{"rateLimits":{"primary":{"usedPercent":120,"windowDurationMins":300,"resetsAt":null},"secondary":{"usedPercent":0,"windowDurationMins":10080}}}"#.utf8))
        #expect(result.windows.map(\.usedPercent) == [100, 0])
        #expect(result.windows.map(\.label) == ["5 小时", "周"])
        #expect(result.windows[0].resetAt == nil)
    }

    @Test func absentOrMalformedCodexLimitsAreNotZeroUsage() {
        for json in [#"{"rateLimits":null}"#, #"{"rateLimits":{"primary":{"windowDurationMins":300}}}"#, #"{"rateLimits":{"primary":{"usedPercent":true,"windowDurationMins":300}}}"#] {
            #expect(throws: (any Error).self) { try CodexUsageParser.parse(Data(json.utf8)) }
        }
    }

    @Test func claudeParsesAllAvailableWindowsAndResetTimes() throws {
        let data = Data(#"{"five_hour":{"utilization":42.5,"resets_at":"2026-10-20T10:00:00.123456Z"},"seven_day":{"utilization":0,"resets_at":null},"seven_day_sonnet":{"utilization":17,"resets_at":"2026-10-22T10:00:00Z"},"seven_day_opus":null,"extra_usage":{"is_enabled":false}}"#.utf8)
        let result = try ClaudeUsageParser.parse(data)
        #expect(result.windows.map(\.label) == ["5 小时", "周", "Sonnet 周"])
        #expect(result.windows.map(\.usedPercent) == [42.5, 0, 17])
        #expect(result.windows[0].resetAt != nil)
        #expect(result.windows[1].resetAt == nil)
    }

    @Test func missingClaudeQuotaIsAnError() {
        for json in ["{}", #"{"five_hour":null}"#, #"{"five_hour":{"resets_at":null}}"#, #"{"five_hour":{"utilization":true}}"#] {
            #expect(throws: (any Error).self) { try ClaudeUsageParser.parse(Data(json.utf8)) }
        }
    }

    @Test func claudeCredentialsRequireSubscriptionToken() throws {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"test-token","expiresAt":2000000000000,"scopes":["user:profile"],"subscriptionType":"max"}}"#.utf8)
        #expect(try ClaudeLocalCredentials.accessToken(from: data) == "test-token")
        #expect(throws: (any Error).self) { try ClaudeLocalCredentials.accessToken(from: Data(#"{"apiKey":"test"}"#.utf8)) }
    }

    @Test func staleAccessTokenTimestampDoesNotMeanSubscriptionLoginExpired() throws {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"stale-token","expiresAt":1,"refreshToken":"renewable-session"}}"#.utf8)
        #expect(try ClaudeLocalCredentials.accessToken(from: data) == "stale-token")
    }
}

@MainActor
struct LocalUsageModelTests {
    @Test func localAccountsRefreshWithoutAPIKeys() async {
        let summary = ProviderUsageSummary(windows: [UsageWindow(label: "周", usedPercent: 28, resetAt: nil)])
        let codex = MockProvider(id: .codex, result: .success(summary))
        let claude = MockProvider(id: .claude, result: .failure(UsageFetchError.unauthorized("请先登录 Claude Code")))
        let model = UsageModel(providers: [codex, claude], keyStore: InMemoryKeyStore())
        await model.refreshNow()
        #expect(model.states[.codex] == .loaded(summary))
        #expect(model.states[.claude] == .failed("请先登录 Claude Code"))
        #expect(model.configured == [.codex, .claude])
    }

    @Test func deletingKeyDuringRefreshDoesNotResurrectOldResult() async {
        let provider = SuspendedUsageProvider()
        let store = InMemoryKeyStore()
        store.keys[.kimi] = "old-key"
        let model = UsageModel(providers: [provider], keyStore: store)
        let task = Task { await model.refreshNow() }
        while !(await provider.isWaiting) { await Task.yield() }
        model.deleteKey(for: .kimi)
        await provider.finish()
        await task.value
        #expect(model.states[.kimi] == .unconfigured)
        #expect(!model.isRefreshing)
    }

    @Test func deletingOneKeyDoesNotDiscardOtherProvidersInFlight() async {
        let kimi = SuspendedUsageProvider()
        let codex = SuspendedUsageProvider(id: .codex)
        let store = InMemoryKeyStore()
        store.keys[.kimi] = "old-key"
        let model = UsageModel(providers: [kimi, codex], keyStore: store)
        let task = Task { await model.refreshNow() }
        while !(await kimi.isWaiting) { await Task.yield() }
        while !(await codex.isWaiting) { await Task.yield() }
        model.deleteKey(for: .kimi)
        await kimi.finish()
        await codex.finish()
        await task.value
        #expect(model.states[.kimi] == .unconfigured)
        #expect(model.states[.codex] == .loaded(ProviderUsageSummary(windows: [UsageWindow(label: "5 小时", usedPercent: 99, resetAt: nil)])))
    }
}

private actor SuspendedUsageProvider: UsageProviding {
    nonisolated let id: UsageProviderID
    init(id: UsageProviderID = .kimi) { self.id = id }
    private var continuation: CheckedContinuation<ProviderUsageSummary, Never>?
    var isWaiting: Bool { continuation != nil }
    func fetchUsage(key: String) async throws -> ProviderUsageSummary {
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        continuation?.resume(returning: ProviderUsageSummary(windows: [UsageWindow(label: "5 小时", usedPercent: 99, resetAt: nil)]))
        continuation = nil
    }
}

struct CodexTransportTests {
    @Test func childCanFindRuntimeNextToSelectedCLI() throws {
        let executable = try fixture("""
        project-dashboard-test-runtime || exit 10
        read -r request
        printf '%s\\n' '{"id":1,"result":{}}'
        read -r notification
        read -r request
        printf '%s\\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":300}}}}'
        read -r done
        """)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let runtime = executable.deletingLastPathComponent().appendingPathComponent("project-dashboard-test-runtime")
        try "#!/bin/sh\nexit 0\n".write(to: runtime, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
        let result = try CodexUsageParser.parse(CodexRPCClient(executable: executable, timeout: 2).readRateLimits())
        #expect(result.windows.first?.usedPercent == 10)
    }

    @Test func childClosingInputDuringHandshakeDoesNotCrashDashboard() throws {
        let executable = try fixture("read -r request\nexec 0<&-\nprintf '%s\\n' '{\"id\":1,\"result\":{}}'\nexit 0")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        #expect(throws: (any Error).self) {
            try CodexRPCClient(executable: executable, timeout: 1).readRateLimits()
        }
    }

    @Test func performsHandshakeAndIgnoresNotifications() throws {
        let executable = try fixture("""
        read -r request
        case "$request" in *initialize*) ;; *) exit 2;; esac
        printf '%s\\n' '{"id":1,"result":{}}'
        read -r notification
        case "$notification" in *initialized*) ;; *) exit 3;; esac
        read -r request
        case "$request" in *account*rateLimits*read*) ;; *) exit 4;; esac
        printf '%s\\n' '{"method":"account/updated","params":{}}'
        printf '%s' '{"id":2,"result":{"rateLimits":{"primary":'
        printf '%s\\n' '{"usedPercent":28,"windowDurationMins":10080}}}}'
        read -r done
        """)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let result = try CodexUsageParser.parse(CodexRPCClient(executable: executable, timeout: 2).readRateLimits())
        #expect(result.windows == [UsageWindow(label: "周", usedPercent: 28, resetAt: nil)])
    }

    @Test func errorsDoNotExposeServerPayloads() throws {
        let executable = try fixture("read -r request\nprintf '%s\\n' '{\"id\":1,\"error\":{\"message\":\"private-token-marker\"}}'\nread -r done")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        do {
            _ = try CodexRPCClient(executable: executable, timeout: 2).readRateLimits()
            Issue.record("Expected failed login")
        } catch { #expect(!error.localizedDescription.contains("private-token-marker")) }
    }

    @Test func unresponsiveChildHasBoundedLifetime() throws {
        let executable = try fixture("read -r request\nread -r never")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let start = Date()
        #expect(throws: (any Error).self) { try CodexRPCClient(executable: executable, timeout: 0.1).readRateLimits() }
        #expect(Date().timeIntervalSince(start) < 3)
    }

    private func fixture(_ script: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("codex")
        try ("#!/bin/sh\n" + script + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
}
