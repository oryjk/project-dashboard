import Combine
import Foundation
import SwiftUI

/// Token 用量区块的状态编排：并行查询已配置的提供商，各自独立落状态。
/// 独立于 DashboardModel（单一职责），App 入口创建后注入。
@MainActor
final class UsageModel: ObservableObject {
    /// 自动刷新节流窗口（秒）
    static let throttleInterval: TimeInterval = 300
    private static let failureRetryInterval: TimeInterval = 30

    /// 并发查询结果（TaskGroup 元素需 Sendable）
    private enum ProviderOutcome: Sendable {
        case loaded(ProviderUsageSummary)
        case failed(String)
    }

    @Published private(set) var states: [UsageProviderID: UsageState]
    @Published private(set) var isRefreshing = false
    @Published private(set) var configured: Set<UsageProviderID>

    let providers: [any UsageProviding]

    private let keyStore: any UsageKeyStore
    private let now: () -> Date
    /// 上次刷新尝试时间（供 UI 计算自动刷新倒计时）
    @Published private(set) var lastRefreshAttempt: Date?
    /// 周期刷新定时器订阅（随面板开关启停）
    private var refreshCancellable: AnyCancellable?
    private var refreshGeneration = 0
    private var credentialGenerations: [UsageProviderID: Int] = [:]
    private var providerAttempts: [UsageProviderID: Date] = [:]

    init(
        providers: [any UsageProviding] = [CodexUsageProvider(), ClaudeUsageProvider(), KimiUsageProvider(), GLMUsageProvider()],
        keyStore: any UsageKeyStore = KeychainStore(),
        now: @escaping () -> Date = Date.init
    ) {
        self.providers = providers
        self.keyStore = keyStore
        self.now = now
        // 先用局部变量计算，self 在全部存储属性初始化完成前不可访问
        let configured = Set(providers.map(\.id).filter { $0.usesLocalAccount || keyStore.readKey(for: $0) != nil })
        var initial: [UsageProviderID: UsageState] = [:]
        for id in providers.map(\.id) {
            // 已配置但未查询过：面板未打开时保持 loading 无副作用，
            // 首次 onAppear 会立即触发真实查询
            initial[id] = configured.contains(id) ? .loading : .unconfigured
        }
        self.states = initial
        self.configured = configured
    }

    /// 成功项维持 5 分钟节流；失败项每 30 秒重试，及时跟随 CLI 续期后的凭据。
    func refreshIfNeeded() async {
        guard !isRefreshing else { return }
        if let last = lastRefreshAttempt,
           now().timeIntervalSince(last) < Self.throttleInterval {
            let retry = Set(configured.filter { id in
                guard case .failed = states[id], let attempt = providerAttempts[id] else { return false }
                return now().timeIntervalSince(attempt) >= Self.failureRetryInterval
            })
            if !retry.isEmpty { await refreshProviders(retry) }
            return
        }
        await refreshNow()
    }

    /// 立即刷新全部已配置的提供商（手动 ⟳、保存 key 后调用），并行且互不影响
    func refreshNow() async {
        lastRefreshAttempt = now()
        await refreshProviders(configured)
    }

    private func refreshProviders(_ ids: Set<UsageProviderID>) async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let credentials = credentialGenerations

        // 先取好 key 再进并发组，避免在非隔离上下文触碰 MainActor 状态。
        // configured 已包含但 key 读不回（如 Keychain 写入静默失败）的提供商，
        // 直接落失败态并给出可恢复指引，避免行永久停留在 loading 且 ⟳ 无法自救
        var configuredProviders: [(provider: any UsageProviding, key: String)] = []
        for provider in providers where ids.contains(provider.id) && configured.contains(provider.id) {
            providerAttempts[provider.id] = now()
            if provider.id.usesLocalAccount {
                configuredProviders.append((provider, ""))
            } else if let key = keyStore.readKey(for: provider.id) {
                configuredProviders.append((provider, key))
            } else {
                states[provider.id] = .failed("Key 读取失败，请在设置中重新保存")
            }
        }
        guard !configuredProviders.isEmpty else { isRefreshing = false; return }

        isRefreshing = true
        defer { if generation == refreshGeneration { isRefreshing = false } }
        for entry in configuredProviders {
            states[entry.provider.id] = .loading
        }

        // Swift 6 严格并发：TaskGroup 的元素类型必须 Sendable，
        // Result<_, Error> 不满足，故用自定义结果枚举
        await withTaskGroup(of: (UsageProviderID, ProviderOutcome).self) { group in
            for entry in configuredProviders {
                group.addTask {
                    do {
                        let summary = try await entry.provider.fetchUsage(key: entry.key)
                        return (entry.provider.id, .loaded(summary))
                    } catch {
                        return (entry.provider.id, .failed(error.localizedDescription))
                    }
                }
            }
            for await (id, outcome) in group {
                guard generation == refreshGeneration, configured.contains(id),
                      credentials[id, default: 0] == credentialGenerations[id, default: 0] else { continue }
                switch outcome {
                case .loaded(let summary):
                    states[id] = .loaded(summary)
                case .failed(let message):
                    states[id] = .failed(message)
                }
            }
        }
    }

    /// 面板打开期间启动周期刷新：每 10 秒 tick 一次，节流检查在 tick 内完成
    /// （成功项每 300 秒查询，失败项每 30 秒重试）
    func startPeriodicRefresh() {
        stopPeriodicRefresh()
        refreshCancellable = Timer.publish(every: 10, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.refreshIfNeeded() }
            }
    }

    /// 面板关闭时停止，避免后台空转
    func stopPeriodicRefresh() {
        refreshCancellable?.cancel()
        refreshCancellable = nil
    }

    /// 定时器回调的可测入口（供单元测试直接调用，绕过真实 Timer）
    func tickNow() async {
        await refreshIfNeeded()
    }

    /// 设置弹层打开时回填已保存的 Key；只用于 SecureField，不持有额外副本。
    func savedKey(for id: UsageProviderID) -> String? {
        guard !id.usesLocalAccount else { return nil }
        return keyStore.readKey(for: id)
    }

    /// 保存 key 并立即刷新（设置弹层调用）
    func saveKey(_ key: String, for id: UsageProviderID) {
        guard !id.usesLocalAccount else { return }
        credentialGenerations[id, default: 0] += 1
        keyStore.saveKey(key, for: id)
        configured.insert(id)
        states[id] = .loading
        Task { await refreshNow() }
    }

    /// 清除 key，回到未配置态（设置弹层调用）
    func deleteKey(for id: UsageProviderID) {
        guard !id.usesLocalAccount else { return }
        credentialGenerations[id, default: 0] += 1
        keyStore.deleteKey(for: id)
        configured.remove(id)
        states[id] = .unconfigured
    }
}
