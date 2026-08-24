import Foundation
import SwiftUI

/// Token 用量区块的状态编排：并行查询已配置的提供商，各自独立落状态。
/// 独立于 DashboardModel（单一职责），App 入口创建后注入。
@MainActor
final class UsageModel: ObservableObject {
    /// 自动刷新节流窗口（秒）
    static let throttleInterval: TimeInterval = 300

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
    private var lastRefreshAttempt: Date?

    init(
        providers: [any UsageProviding] = [KimiUsageProvider(), GLMUsageProvider()],
        keyStore: any UsageKeyStore = KeychainStore()
    ) {
        self.providers = providers
        self.keyStore = keyStore
        // 先用局部变量计算，self 在全部存储属性初始化完成前不可访问
        let configured = Set(providers.map(\.id).filter { keyStore.readKey(for: $0) != nil })
        var initial: [UsageProviderID: UsageState] = [:]
        for id in providers.map(\.id) {
            // 已配置但未查询过：面板未打开时保持 loading 无副作用，
            // 首次 onAppear 会立即触发真实查询
            initial[id] = configured.contains(id) ? .loading : .unconfigured
        }
        self.states = initial
        self.configured = configured
    }

    /// 面板 onAppear 入口：距上次刷新尝试不足节流窗口时跳过
    func refreshIfNeeded() async {
        if let last = lastRefreshAttempt,
           Date().timeIntervalSince(last) < Self.throttleInterval {
            return
        }
        await refreshNow()
    }

    /// 立即刷新全部已配置的提供商（手动 ⟳、保存 key 后调用），并行且互不影响
    func refreshNow() async {
        lastRefreshAttempt = Date()

        // 先取好 key 再进并发组，避免在非隔离上下文触碰 MainActor 状态。
        // configured 已包含但 key 读不回（如 Keychain 写入静默失败）的提供商，
        // 直接落失败态并给出可恢复指引，避免行永久停留在 loading 且 ⟳ 无法自救
        var configuredProviders: [(provider: any UsageProviding, key: String)] = []
        for provider in providers where configured.contains(provider.id) {
            if let key = keyStore.readKey(for: provider.id) {
                configuredProviders.append((provider, key))
            } else {
                states[provider.id] = .failed("Key 读取失败，请在设置中重新保存")
            }
        }
        guard !configuredProviders.isEmpty else { return }

        isRefreshing = true
        defer { isRefreshing = false }
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
                switch outcome {
                case .loaded(let summary):
                    states[id] = .loaded(summary)
                case .failed(let message):
                    states[id] = .failed(message)
                }
            }
        }
    }

    /// 保存 key 并立即刷新（设置弹层调用）
    func saveKey(_ key: String, for id: UsageProviderID) {
        keyStore.saveKey(key, for: id)
        configured.insert(id)
        states[id] = .loading
        Task { await refreshNow() }
    }

    /// 清除 key，回到未配置态（设置弹层调用）
    func deleteKey(for id: UsageProviderID) {
        keyStore.deleteKey(for: id)
        configured.remove(id)
        states[id] = .unconfigured
    }
}
