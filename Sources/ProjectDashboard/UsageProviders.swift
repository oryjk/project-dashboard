import Foundation

// MARK: - 统一数据模型

/// 提供商标识（后续扩展新提供商时在此追加 case）
enum UsageProviderID: String, CaseIterable, Hashable, Sendable {
    case kimi
    case glm

    var displayName: String {
        switch self {
        case .kimi: "Kimi"
        case .glm: "GLM"
        }
    }
}

/// 归一化后的用量摘要：已用百分比 + 窗口重置时间
struct ProviderUsageSummary: Equatable, Sendable {
    /// 当前窗口已用百分比，0...100
    let usedPercent: Double
    /// 窗口重置时间；GLM 接口不提供则为 nil
    let resetAt: Date?
}

/// 单个提供商的展示状态
enum UsageState: Equatable, Sendable {
    case unconfigured
    case loading
    case loaded(ProviderUsageSummary)
    case failed(String)
}

enum UsageFetchError: Error, Equatable, LocalizedError {
    /// key 无效（各家 key 易混淆点不同，附带具体中文提示）
    case unauthorized(String)
    case http(Int)
    case network
    case parsing
    case missingLimit

    var errorDescription: String? {
        switch self {
        case .unauthorized(let hint): hint
        case .http(let code): "服务返回错误（HTTP \(code)）"
        case .network: "网络请求失败，请检查网络连接"
        case .parsing: "接口返回格式变化，解析失败"
        case .missingLimit: "接口未返回限额信息"
        }
    }
}

/// 非敏感设置项的 UserDefaults key（key 本身只存 Keychain）
enum UsageSettings {
    /// GLM 是否使用国际版域名（false = 国内版 open.bigmodel.cn）
    static let glmInternationalKey = "usage.glm.useInternational"
}

// MARK: - Kimi 解析（纯函数）

/// 解析 Kimi Code 平台用量响应。
/// 兼容两种结构（字段名以 kimi-cli 与 kimi-code-usage 项目实测为准）：
///   新 /usages：{"data": [{"model_name": "all", "used":…, "limit":…, "resetTime":…}, …]}
///   旧 /usage：{"usage": {…}, "limits": […]}
enum KimiUsageParser {
    static func parse(_ data: Data) throws -> ProviderUsageSummary {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let payload = obj as? [String: Any] else {
            throw UsageFetchError.parsing
        }

        // 汇总行：新结构取 data 数组中 model_name == "all"；旧结构取 usage 对象
        var fields: [String: Any]?
        if let list = payload["data"] as? [[String: Any]] {
            fields = list.first { ($0["model_name"] as? String) == "all" }
        } else if let usage = payload["usage"] as? [String: Any] {
            fields = usage
        }
        guard let fields else { throw UsageFetchError.parsing }

        let limit = intValue(fields, keys: ["limit", "limit_amount"])
        guard let limit, limit > 0 else { throw UsageFetchError.missingLimit }

        let used = intValue(fields, keys: ["used", "used_amount"])
            ?? intValue(fields, keys: ["remaining"]).map { limit - $0 }

        let percent = min(max(Double(used ?? 0) / Double(limit) * 100, 0), 100)
        return ProviderUsageSummary(usedPercent: percent, resetAt: resetDate(fields))
    }

    /// 多字段名容错取整数值
    private static func intValue(_ fields: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let n = fields[key] as? NSNumber { return n.intValue }
            if let s = fields[key] as? String, let v = Int(s) { return v }
        }
        return nil
    }

    /// resetTime 兼容秒级时间戳与 ISO8601 字符串两种格式
    private static func resetDate(_ fields: [String: Any]) -> Date? {
        for key in ["resetTime", "reset_at", "reset_time"] {
            guard let value = fields[key] else { continue }
            if let n = value as? NSNumber, n.doubleValue > 0 {
                return Date(timeIntervalSince1970: n.doubleValue)
            }
            if let s = value as? String,
               let d = ISO8601DateFormatter().date(from: s) {
                return d
            }
        }
        return nil
    }
}

// MARK: - GLM 解析（纯函数）

/// 解析智谱 quota/limit 响应（字段名以官方插件 glm-plan-usage 的 query-usage.mjs 为准）。
/// 兼容 {"data": {"limits": […]}} 与 {"limits": […]} 两种包裹；
/// 取 type == "TOKENS_LIMIT"（5 小时 Token 窗口）的 percentage。
enum GLMUsageParser {
    static func parse(_ data: Data) throws -> ProviderUsageSummary {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let root0 = obj as? [String: Any] else {
            throw UsageFetchError.parsing
        }
        let root = (root0["data"] as? [String: Any]) ?? root0
        guard let limits = root["limits"] as? [[String: Any]] else {
            throw UsageFetchError.parsing
        }
        guard let tokenLimit = limits.first(where: { ($0["type"] as? String) == "TOKENS_LIMIT" }),
              let percent = tokenLimit["percentage"] as? NSNumber else {
            throw UsageFetchError.parsing
        }
        // 该端点不返回窗口重置时间
        return ProviderUsageSummary(
            usedPercent: min(max(percent.doubleValue, 0), 100),
            resetAt: nil
        )
    }
}

// MARK: - Provider 协议与网络实现

/// 一家提供商的用量查询实现。新增提供商 = 新增一个遵守本协议的类型
protocol UsageProviding: Sendable {
    var id: UsageProviderID { get }
    func fetchUsage(key: String) async throws -> ProviderUsageSummary
}

/// 请求/响应的公共处理：401 → 带提示的 unauthorized，其他非 200 → http，
/// URLError → network。body 交给调用方各自的 parser。
private func checkedData(from data: Data, response: URLResponse, unauthorizedHint: String) throws -> Data {
    guard let http = response as? HTTPURLResponse else {
        throw UsageFetchError.network
    }
    switch http.statusCode {
    case 200:
        return data
    case 401:
        throw UsageFetchError.unauthorized(unauthorizedHint)
    default:
        throw UsageFetchError.http(http.statusCode)
    }
}

/// 将底层网络异常归一化为 UsageFetchError
private func mapNetworkError(_ error: Error) -> UsageFetchError {
    if let usageError = error as? UsageFetchError { return usageError }
    return .network
}

/// Kimi Code 平台（Coding Plan 会员）用量查询。
/// 端点与认证头以开源项目 kimi-code-usage 实测为准：
///   GET https://api.kimi.com/coding/v1/usages（404 时回退 /usage）
///   Authorization: Bearer {key}，User-Agent: KimiCLI/1.6（服务端按 UA 区分客户端）
struct KimiUsageProvider: UsageProviding {
    let id = UsageProviderID.kimi

    private static let base = URL(string: "https://api.kimi.com/coding/v1")!

    func fetchUsage(key: String) async throws -> ProviderUsageSummary {
        do {
            let data = try await get(path: "usages", key: key)
            return try KimiUsageParser.parse(data)
        } catch UsageFetchError.http(404) {
            // 旧端点回退
            let data = try await get(path: "usage", key: key)
            return try KimiUsageParser.parse(data)
        }
    }

    private func get(path: String, key: String) async throws -> Data {
        var request = URLRequest(url: Self.base.appendingPathComponent(path))
        request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("KimiCLI/1.6", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return try checkedData(from: data, response: response, unauthorizedHint: """
                认证失败：请确认使用 Kimi Code 控制台的 sk-kimi- 开头 Key，\
                而非开放平台（platform.kimi.com）的 Key
                """)
        } catch {
            throw mapNetworkError(error)
        }
    }
}

/// 智谱 GLM Coding Plan 用量查询。
/// 端点与认证头以官方插件仓库 zai-coding-plugins 的 query-usage.mjs 为准：
///   GET {domain}/api/monitor/usage/quota/limit
///   Authorization: {key}（注意：不带 Bearer 前缀）
struct GLMUsageProvider: UsageProviding {
    let id = UsageProviderID.glm

    private var domain: URL {
        if UserDefaults.standard.bool(forKey: UsageSettings.glmInternationalKey) {
            URL(string: "https://api.z.ai")!
        } else {
            URL(string: "https://open.bigmodel.cn")!
        }
    }

    func fetchUsage(key: String) async throws -> ProviderUsageSummary {
        var request = URLRequest(url: domain.appendingPathComponent("api/monitor/usage/quota/limit"))
        request.timeoutInterval = 10
        request.setValue(key, forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let checked = try checkedData(
                from: data, response: response,
                unauthorizedHint: "认证失败：请确认使用 GLM Coding Plan 的 API Key"
            )
            return try GLMUsageParser.parse(checked)
        } catch {
            throw mapNetworkError(error)
        }
    }
}
