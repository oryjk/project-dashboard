import Foundation
import Testing
@testable import ProjectDashboard

// MARK: - 测试替身

final class MockProvider: UsageProviding, @unchecked Sendable {
    let id: UsageProviderID
    private let result: Result<ProviderUsageSummary, Error>
    private(set) var fetchCount = 0
    private(set) var lastKey: String?

    init(id: UsageProviderID, result: Result<ProviderUsageSummary, Error>) {
        self.id = id
        self.result = result
    }

    func fetchUsage(key: String) async throws -> ProviderUsageSummary {
        fetchCount += 1
        lastKey = key
        switch result {
        case .success(let summary): return summary
        case .failure(let error): throw error
        }
    }
}

final class InMemoryKeyStore: UsageKeyStore, @unchecked Sendable {
    var keys: [UsageProviderID: String] = [:]
    /// 模拟 Keychain 静默故障：saveKey 照常落内存，但 readKey 始终读不回
    var readAlwaysFails = false
    func readKey(for id: UsageProviderID) -> String? { readAlwaysFails ? nil : keys[id] }
    func saveKey(_ key: String, for id: UsageProviderID) { keys[id] = key }
    func deleteKey(for id: UsageProviderID) { keys[id] = nil }
}

// MARK: - 测试

@MainActor
struct UsageModelTests {
    private let okSummary = ProviderUsageSummary(windows: [
        UsageWindow(label: "5 小时", usedPercent: 42, resetAt: nil)
    ])

    @Test func refreshLoadsConfiguredProvider() async {
        let provider = MockProvider(id: .kimi, result: .success(okSummary))
        let store = InMemoryKeyStore()
        store.keys[.kimi] = "sk-kimi-test"
        let model = UsageModel(providers: [provider], keyStore: store)

        await model.refreshNow()

        #expect(provider.fetchCount == 1)
        #expect(provider.lastKey == "sk-kimi-test")
        #expect(model.states[.kimi] == .loaded(okSummary))
        #expect(model.configured == [.kimi])
    }

    @Test func unconfiguredProviderIsSkipped() async {
        let provider = MockProvider(id: .kimi, result: .success(okSummary))
        let model = UsageModel(providers: [provider], keyStore: InMemoryKeyStore())

        await model.refreshNow()

        #expect(provider.fetchCount == 0)
        #expect(model.states[.kimi] == .unconfigured)
    }

    @Test func failureOfOneProviderDoesNotAffectTheOther() async {
        let kimi = MockProvider(
            id: .kimi,
            result: .failure(UsageFetchError.unauthorized("认证失败：请确认使用 Kimi Code 控制台的 sk-kimi- 开头 Key，而非开放平台（platform.kimi.com）的 Key"))
        )
        let glm = MockProvider(id: .glm, result: .success(okSummary))
        let store = InMemoryKeyStore()
        store.keys[.kimi] = "bad"
        store.keys[.glm] = "good"
        let model = UsageModel(providers: [kimi, glm], keyStore: store)

        await model.refreshNow()

        #expect(model.states[.kimi] == .failed("认证失败：请确认使用 Kimi Code 控制台的 sk-kimi- 开头 Key，而非开放平台（platform.kimi.com）的 Key"))
        #expect(model.states[.glm] == .loaded(okSummary))
    }

    @Test func refreshIfNeededThrottlesWithinInterval() async {
        let provider = MockProvider(id: .kimi, result: .success(okSummary))
        let store = InMemoryKeyStore()
        store.keys[.kimi] = "k"
        let model = UsageModel(providers: [provider], keyStore: store)

        await model.refreshIfNeeded()
        #expect(provider.fetchCount == 1)

        // 节流窗口内（300 秒）第二次 onAppear 不应再次请求
        await model.refreshIfNeeded()
        #expect(provider.fetchCount == 1)

        // 强制刷新不受节流限制
        await model.refreshNow()
        #expect(provider.fetchCount == 2)
    }

    @Test func keyReadFailureMarksProviderFailedInsteadOfLoading() async {
        let provider = MockProvider(id: .kimi, result: .success(okSummary))
        let store = InMemoryKeyStore()
        store.keys[.kimi] = "sk-kimi-test"
        let model = UsageModel(providers: [provider], keyStore: store)
        #expect(model.configured == [.kimi])

        // 模拟 saveKey 后 Keychain 读取静默失败：configured 已置位但 readKey 返回 nil
        store.readAlwaysFails = true
        await model.refreshNow()

        // 不应停留在 loading，而应落可恢复的 failed 态，且不发起请求
        #expect(model.states[.kimi] == .failed("Key 读取失败，请在设置中重新保存"))
        #expect(provider.fetchCount == 0)
        #expect(model.isRefreshing == false)
    }

    @Test func saveAndDeleteKeyUpdateConfiguredState() async {
        let provider = MockProvider(id: .kimi, result: .success(okSummary))
        let store = InMemoryKeyStore()
        let model = UsageModel(providers: [provider], keyStore: store)

        model.saveKey("new-key", for: .kimi)
        #expect(model.configured == [.kimi])
        #expect(store.keys[.kimi] == "new-key")

        model.deleteKey(for: .kimi)
        #expect(model.configured.isEmpty)
        #expect(store.keys[.kimi] == nil)
    }

    @Test func tickNowRespectsThrottleAndFiresAfterInterval() async {
        let provider = MockProvider(id: .kimi, result: .success(okSummary))
        let store = InMemoryKeyStore()
        store.keys[.kimi] = "k"
        let model = UsageModel(providers: [provider], keyStore: store)

        await model.tickNow()   // 首次：发起请求
        #expect(provider.fetchCount == 1)

        await model.tickNow()   // 节流窗口内：不请求
        #expect(provider.fetchCount == 1)
        #expect(model.lastRefreshAttempt != nil)
    }

    @Test func stopPeriodicRefreshCancelsTimer() {
        let provider = MockProvider(id: .kimi, result: .success(okSummary))
        let store = InMemoryKeyStore()
        store.keys[.kimi] = "k"
        let model = UsageModel(providers: [provider], keyStore: store)

        model.startPeriodicRefresh()
        model.stopPeriodicRefresh()
        // 停止后可重复调用不崩溃、状态干净
        model.stopPeriodicRefresh()
        #expect(model.isRefreshing == false)
    }
}
