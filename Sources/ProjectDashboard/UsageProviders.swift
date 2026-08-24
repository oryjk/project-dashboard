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

/// 单个限额窗口的用量
struct UsageWindow: Equatable, Sendable {
    /// 展示名："5 小时"、"周"
    let label: String
    /// 当前窗口已用百分比，0...100
    let usedPercent: Double
    /// 窗口重置时间；接口不提供则为 nil
    let resetAt: Date?
}

/// 归一化后的用量摘要：按展示顺序排列的窗口列表（5h 在前，周在后）
struct ProviderUsageSummary: Equatable, Sendable {
    let windows: [UsageWindow]
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
///   新 /usages：{"data": [{"model_name": "all", …}, {"model_name": "kimi-k2", "name": "…", …}]}
///     "all" 行为周用量汇总，其余行为限额窗口（5 小时等）
///   旧 /usage：{"usage": {…}, "limits": […]}，usage 为周用量，limits 为各限额窗口
/// 窗口顺序：限额窗口在前（按 API 返回顺序），周窗口最后。
enum KimiUsageParser {
    static func parse(_ data: Data) throws -> ProviderUsageSummary {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let payload = obj as? [String: Any] else {
            throw UsageFetchError.parsing
        }

        if let list = payload["data"] as? [[String: Any]] {
            return try parseNewShape(list)
        }
        if let usage = payload["usage"] as? [String: Any] {
            return try parseOldShape(
                usage: usage,
                limits: payload["limits"] as? [[String: Any]] ?? []
            )
        }
        throw UsageFetchError.parsing
    }

    /// 新结构：data 数组。"all" 行缺失 → 解析失败；limit 无效 → 整体失败
    private static func parseNewShape(_ list: [[String: Any]]) throws -> ProviderUsageSummary {
        guard let summaryFields = list.first(where: { ($0["model_name"] as? String) == "all" }) else {
            throw UsageFetchError.parsing
        }
        let weekly = try weeklyWindow(from: summaryFields)

        var windows: [UsageWindow] = []
        for fields in list where (fields["model_name"] as? String) != "all" {
            // 限额窗口 limit 缺失或 <= 0 → 跳过该窗口（不报错）
            guard let limit = intValue(fields, keys: ["limit", "limit_amount"]), limit > 0 else { continue }
            // label 取行内 name/title 原文（含数字小时语义不翻译）；皆无时用兜底名
            let label = (fields["name"] as? String) ?? (fields["title"] as? String) ?? "限额窗口"
            windows.append(usageWindow(label: label, limit: limit, fields: fields))
        }
        windows.append(weekly)
        return ProviderUsageSummary(windows: windows)
    }

    /// 旧结构：usage 对象为周用量，limits 各项的 detail 为限额窗口数值
    private static func parseOldShape(usage: [String: Any], limits: [[String: Any]]) throws -> ProviderUsageSummary {
        let weekly = try weeklyWindow(from: usage)

        var windows: [UsageWindow] = []
        for item in limits {
            guard let detail = item["detail"] as? [String: Any] else { continue }
            // 数值解析规则与新结构限额窗口相同：limit 缺失或 <= 0 → 跳过
            guard let limit = intValue(detail, keys: ["limit", "limit_amount"]), limit > 0 else { continue }
            windows.append(usageWindow(
                label: windowLabel(item["window"] as? [String: Any]),
                limit: limit,
                fields: detail
            ))
        }
        windows.append(weekly)
        return ProviderUsageSummary(windows: windows)
    }

    /// 周窗口："all" 行或旧结构 usage 对象；limit 缺失或无效 → 整体失败
    private static func weeklyWindow(from fields: [String: Any]) throws -> UsageWindow {
        let limit = intValue(fields, keys: ["limit", "limit_amount"])
        guard let limit, limit > 0 else { throw UsageFetchError.missingLimit }
        return usageWindow(label: "周", limit: limit, fields: fields)
    }

    /// 由 limit 与 used（含 remaining 变体）构造单个窗口，百分比钳制到 0...100
    private static func usageWindow(label: String, limit: Int, fields: [String: Any]) -> UsageWindow {
        let used = intValue(fields, keys: ["used", "used_amount"])
            ?? intValue(fields, keys: ["remaining"]).map { limit - $0 }
        let percent = min(max(Double(used ?? 0) / Double(limit) * 100, 0), 100)
        return UsageWindow(label: label, usedPercent: percent, resetAt: resetDate(fields))
    }

    /// 旧结构 limits 的窗口 label：由 window.duration + timeUnit 生成中文展示名。
    /// 映射：MINUTE(S) 且可整除 60 → "N 小时"；HOUR(S) → "N 小时"；DAY(S) → "N 天"；其余 → "限额窗口"
    private static func windowLabel(_ window: [String: Any]?) -> String {
        guard let window,
              let duration = (window["duration"] as? NSNumber)?.intValue else { return "限额窗口" }
        switch (window["timeUnit"] as? String ?? "").uppercased() {
        case "HOUR", "HOURS":
            return "\(duration) 小时"
        case "DAY", "DAYS":
            return "\(duration) 天"
        case "MINUTE", "MINUTES":
            return duration > 0 && duration % 60 == 0 ? "\(duration / 60) 小时" : "限额窗口"
        default:
            return "限额窗口"
        }
    }

    /// 多字段名容错取整数值
    private static func intValue(_ fields: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let n = fields[key] as? NSNumber { return n.intValue }
            if let s = fields[key] as? String, let v = Int(s) { return v }
        }
        return nil
    }

    /// resetTime 兼容秒级时间戳与 ISO8601 字符串两种格式；
    /// 绝对字段顺序与官方 kimi-cli _reset_hint 一致（reset_at / resetAt /
    /// reset_time / resetTime）；
    /// 都不命中时回退相对秒数字段（reset_in / resetIn / ttl，另加 window——
    /// 仅当值为数字且 > 0 时按秒数处理；limits 结构里 window 通常是
    /// {duration, timeUnit} 对象，非数字自然跳过），锚定解析时刻 now + seconds
    private static func resetDate(_ fields: [String: Any]) -> Date? {
        for key in ["reset_at", "resetAt", "reset_time", "resetTime"] {
            guard let value = fields[key] else { continue }
            if let n = value as? NSNumber, n.doubleValue > 0 {
                return Date(timeIntervalSince1970: n.doubleValue)
            }
            if let s = value as? String,
               let d = parseISO8601Flexible(s) {
                return d
            }
        }
        // 回退：相对秒数字段（> 0 才有效），锚定解析时刻
        if let resetIn = intValue(fields, keys: ["reset_in", "resetIn", "ttl"]), resetIn > 0 {
            return Date(timeIntervalSinceNow: TimeInterval(resetIn))
        }
        if let window = fields["window"] as? NSNumber, window.doubleValue > 0 {
            return Date(timeIntervalSinceNow: window.doubleValue)
        }
        return nil
    }

    /// 宽容解析 ISO8601 字符串：真实接口时间戳带纳秒级小数
    /// （官方示例 "2025-12-23T05:24:18.443553353Z"，官方代码同样先截断到微秒），
    /// ISO8601DateFormatter 无法直接解析——先把小数截断到最多 6 位
    /// （保留其后的 Z 或 +hh:mm 时区），再用 withFractionalSeconds 解析；
    /// 无小数则按默认格式解析
    private static func parseISO8601Flexible(_ value: String) -> Date? {
        guard let dot = value.firstIndex(of: ".") else {
            return ISO8601DateFormatter().date(from: value)
        }
        // 小数部分为点号后的连续 ASCII 数字，其后可能紧跟时区后缀（Z / ±hh:mm）
        let afterDot = value.index(after: dot)
        let fractionEnd = value[afterDot...].firstIndex { $0 < "0" || $0 > "9" } ?? value.endIndex
        let kept = min(6, value.distance(from: afterDot, to: fractionEnd))
        let cut = value.index(afterDot, offsetBy: kept)
        let normalized = String(value[..<cut]) + value[fractionEnd...]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: normalized)
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
        // 该端点不返回窗口重置时间；GLM 仅一个 5 小时窗口，单窗口包装
        return ProviderUsageSummary(windows: [
            UsageWindow(label: "5 小时", usedPercent: min(max(percent.doubleValue, 0), 100), resetAt: nil)
        ])
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
