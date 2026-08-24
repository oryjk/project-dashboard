# Token 用量聚合区块 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 my-dashboard（macOS 菜单栏应用）面板顶部新增区块，聚合展示 Kimi for Coding 与 GLM Coding Plan 的 token 用量百分比与重置倒计时。

**Architecture:** 新增 4 个源文件：`UsageProviders.swift`（统一数据模型 + 两家响应解析纯函数 + Provider 协议与网络实现）、`UsageModel.swift`（独立 ObservableObject，状态编排与节流刷新）、`UsageSectionView.swift`（区块 UI + key 设置弹层）、`KeychainStore.swift`（key 存取）。解析与状态编排走 TDD；网络与 UI 手动验收。

**Tech Stack:** Swift 6（严格并发）、SwiftUI、URLSession async/await、Security framework（Keychain）、Swift Testing（`import Testing`）。零第三方依赖。

**Spec:** `docs/superpowers/specs/2026-08-24-token-usage-design.md`

## Global Constraints

- swift-tools-version 6.0，平台 macOS 14+，严格并发（Swift 6 language mode）必须编译通过
- 零第三方依赖（SPM 无任何 dependencies）
- UI 文案全部中文，与现有代码注释风格一致（中文注释）
- API key 只存 Keychain（service `com.carlwang.ProjectDashboard.usage`），不落 UserDefaults、不写日志
- GLM 域名开关存 UserDefaults，key 名 `usage.glm.useInternational`（默认 false = 国内版 `open.bigmodel.cn`）
- 进度条颜色阈值：已用 < 50% 绿、50%–85% 黄、> 85% 红
- 自动刷新节流 300 秒（基于上次刷新尝试，无论成败）；未配置 key 的提供商不发起网络请求
- 沙盒 entitlements 需新增 `com.apple.security.network.client`
- 测试命令：`swift test`（项目根目录）；构建命令：`./build-app.sh`
- **本项目当前不是 git 仓库**：Task 1 会执行 `git init`（可逆操作，删除 `.git/` 即可撤销）
- 参考源码在 `/tmp/usage-research/`（可能已被清理；本计划已内嵌全部所需字段信息，无需依赖它）

---

### Task 1: git 仓库初始化 + SPM testTarget 脚手架

**Files:**
- Create: `.gitignore`
- Modify: `Package.swift`
- Create: `Tests/ProjectDashboardTests/UsageParsingSmokeTests.swift`

**Interfaces:**
- Consumes: 无
- Produces: testTarget `ProjectDashboardTests`，依赖 executable target `ProjectDashboard`（后续任务的测试文件都放这里）

- [ ] **Step 1: 初始化 git 仓库**

```bash
cd /Users/carlwang/projects/my-dashboard
git init
```

- [ ] **Step 2: 创建 .gitignore**

创建 `.gitignore`，内容：

```gitignore
.build/
ProjectDashboard.app/
*.dmg
*.zip
.DS_Store
```

（`.build/` 是 SPM 构建缓存；`ProjectDashboard.app/`、`*.dmg`、`*.zip` 是 build-app.sh 产物，均不入库。）

- [ ] **Step 3: 修改 Package.swift 增加 testTarget**

将 `Package.swift` 整体替换为：

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProjectDashboard",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ProjectDashboard"),
        .testTarget(name: "ProjectDashboardTests", dependencies: ["ProjectDashboard"])
    ]
)
```

- [ ] **Step 4: 创建冒烟测试验证 testTarget 可用**

创建 `Tests/ProjectDashboardTests/UsageParsingSmokeTests.swift`：

```swift
import Testing
@testable import ProjectDashboard

@Test func smokeTestTargetLoads() {
    #expect(1 + 1 == 2)
}
```

- [ ] **Step 5: 运行测试确认通过**

Run: `swift test`
Expected: `Test run with 1 test passed`（或 Swift Testing 等价输出：1 test, 0 failures）

- [ ] **Step 6: Commit**

```bash
git add .gitignore Package.swift Tests/
git commit -m "chore: 初始化 git 仓库并添加测试 target"
```

---

### Task 2: 用量数据模型 + Kimi 响应解析（TDD）

**Files:**
- Create: `Sources/ProjectDashboard/UsageProviders.swift`
- Test: `Tests/ProjectDashboardTests/KimiUsageParserTests.swift`

**Interfaces:**
- Consumes: 无
- Produces（后续任务依赖，签名精确如下）:
  - `enum UsageProviderID: String, CaseIterable, Sendable, Hashable { case kimi, glm }`，属性 `var displayName: String`
  - `struct ProviderUsageSummary: Equatable, Sendable { let usedPercent: Double; let resetAt: Date? }`
  - `enum UsageState: Equatable, Sendable { case unconfigured; case loading; case loaded(ProviderUsageSummary); case failed(String) }`
  - `enum UsageFetchError: Error, Equatable { case unauthorized(String); case http(Int); case network; case parsing; case missingLimit }`，遵守 `LocalizedError`，中文 `errorDescription`
  - `enum KimiUsageParser { static func parse(_ data: Data) throws -> ProviderUsageSummary }`

- [ ] **Step 1: 写失败测试**

创建 `Tests/ProjectDashboardTests/KimiUsageParserTests.swift`：

```swift
import Foundation
import Testing
@testable import ProjectDashboard

struct KimiUsageParserTests {
    // 新端点 /usages 的结构：data 数组，model_name == "all" 为周用量汇总
    @Test func parseNewShapeSummaryRow() throws {
        let json = """
        {"code":0,"data":[
          {"model_name":"all","name":"Weekly Usage","used":800000,"limit":1000000,
           "resetTime":"2026-08-30T00:00:00Z"},
          {"model_name":"kimi-k2","used":300000,"limit":400000}
        ]}
        """
        let summary = try KimiUsageParser.parse(Data(json.utf8))
        #expect(abs(summary.usedPercent - 80.0) < 0.001)
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-08-30T00:00:00Z"))
        #expect(abs(summary.resetAt!.timeIntervalSince(expected)) < 1)
    }

    // 字段名变体：used_amount / limit_amount + 秒级时间戳
    @Test func parseOldShapeFieldVariants() throws {
        let json = """
        {"usage":{"used_amount":40,"limit_amount":100,"reset_at":1755900000},
         "limits":[{"window":{"duration":300,"timeUnit":"MINUTES"},
                    "detail":{"used":10,"limit":100}}]}
        """
        let summary = try KimiUsageParser.parse(Data(json.utf8))
        #expect(abs(summary.usedPercent - 40.0) < 0.001)
        #expect(abs(summary.resetAt!.timeIntervalSince1970 - 1755900000) < 1)
    }

    // 只有 remaining 时：used = limit - remaining
    @Test func parseRemainingOnly() throws {
        let json = """
        {"data":[{"model_name":"all","limit":1000,"remaining":250}]}
        """
        let summary = try KimiUsageParser.parse(Data(json.utf8))
        #expect(abs(summary.usedPercent - 75.0) < 0.001)
        #expect(summary.resetAt == nil)
    }

    // limit 缺失：明确报「接口未返回限额信息」而非通用解析错误
    @Test func missingLimitThrowsMissingLimit() {
        let json = """
        {"data":[{"model_name":"all","used":500}]}
        """
        #expect(throws: UsageFetchError.missingLimit) {
            try KimiUsageParser.parse(Data(json.utf8))
        }
    }

    // 没有汇总行（model_name != "all"）→ 解析失败
    @Test func missingSummaryRowThrowsParsing() {
        let json = """
        {"data":[{"model_name":"kimi-k2","used":1,"limit":2}]}
        """
        #expect(throws: UsageFetchError.parsing) {
            try KimiUsageParser.parse(Data(json.utf8))
        }
    }

    // 非 JSON 或结构完全不符 → 解析失败
    @Test func garbageThrowsParsing() {
        #expect(throws: UsageFetchError.parsing) {
            try KimiUsageParser.parse(Data("not json".utf8))
        }
    }
}
```

- [ ] **Step 2: 运行测试确认编译失败**

Run: `swift test`
Expected: 编译失败，`cannot find 'KimiUsageParser' in scope`（类型尚不存在）

- [ ] **Step 3: 实现 UsageProviders.swift 的数据模型与 Kimi 解析**

创建 `Sources/ProjectDashboard/UsageProviders.swift`：

```swift
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
```

- [ ] **Step 4: 运行测试确认全部通过**

Run: `swift test`
Expected: 全部测试通过（Task 1 冒烟测试 + 本任务 6 个测试）

- [ ] **Step 5: Commit**

```bash
git add Sources/ProjectDashboard/UsageProviders.swift Tests/ProjectDashboardTests/KimiUsageParserTests.swift
git commit -m "feat: Kimi 用量响应解析（含字段变体与限额缺失处理）"
```

---

### Task 3: GLM 响应解析（TDD）

**Files:**
- Modify: `Sources/ProjectDashboard/UsageProviders.swift`（追加 GLMUsageParser）
- Test: `Tests/ProjectDashboardTests/GLMUsageParserTests.swift`

**Interfaces:**
- Consumes: `ProviderUsageSummary`、`UsageFetchError`（Task 2 已定义）
- Produces: `enum GLMUsageParser { static func parse(_ data: Data) throws -> ProviderUsageSummary }`

- [ ] **Step 1: 写失败测试**

创建 `Tests/ProjectDashboardTests/GLMUsageParserTests.swift`：

```swift
import Foundation
import Testing
@testable import ProjectDashboard

struct GLMUsageParserTests {
    // 标准结构：data 包裹 limits，取 TOKENS_LIMIT（5 小时窗口）的 percentage
    @Test func parseStandardShape() throws {
        let json = """
        {"data":{"limits":[
          {"type":"TOKENS_LIMIT","percentage":55.5},
          {"type":"TIME_LIMIT","percentage":10,"currentValue":3,"usage":100}
        ]}}
        """
        let summary = try GLMUsageParser.parse(Data(json.utf8))
        #expect(abs(summary.usedPercent - 55.5) < 0.001)
        #expect(summary.resetAt == nil)
    }

    // 裸结构：limits 在根层级（与 glm-plan-usage 插件的 json.data || json 兼容逻辑一致）
    @Test func parseBareLimitsShape() throws {
        let json = """
        {"limits":[{"type":"TOKENS_LIMIT","percentage":30}]}
        """
        let summary = try GLMUsageParser.parse(Data(json.utf8))
        #expect(abs(summary.usedPercent - 30.0) < 0.001)
    }

    // 超出范围的百分比被钳制到 0...100
    @Test func clampsOutOfRangePercentage() throws {
        let json = """
        {"limits":[{"type":"TOKENS_LIMIT","percentage":130}]}
        """
        let summary = try GLMUsageParser.parse(Data(json.utf8))
        #expect(abs(summary.usedPercent - 100.0) < 0.001)
    }

    // 没有 TOKENS_LIMIT 类型 → 解析失败
    @Test func missingTokenLimitThrowsParsing() {
        let json = """
        {"limits":[{"type":"TIME_LIMIT","percentage":10}]}
        """
        #expect(throws: UsageFetchError.parsing) {
            try GLMUsageParser.parse(Data(json.utf8))
        }
    }

    // 非 JSON → 解析失败
    @Test func garbageThrowsParsing() {
        #expect(throws: UsageFetchError.parsing) {
            try GLMUsageParser.parse(Data("not json".utf8))
        }
    }
}
```

- [ ] **Step 2: 运行测试确认编译失败**

Run: `swift test`
Expected: 编译失败，`cannot find 'GLMUsageParser' in scope`

- [ ] **Step 3: 在 UsageProviders.swift 末尾追加 GLM 解析**

在 `Sources/ProjectDashboard/UsageProviders.swift` 文件末尾追加：

```swift
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
```

- [ ] **Step 4: 运行测试确认全部通过**

Run: `swift test`
Expected: 全部通过（前序任务测试 + 本任务 5 个测试）

- [ ] **Step 5: Commit**

```bash
git add Sources/ProjectDashboard/UsageProviders.swift Tests/ProjectDashboardTests/GLMUsageParserTests.swift
git commit -m "feat: GLM 用量响应解析（TOKENS_LIMIT 窗口百分比）"
```

---

### Task 4: Provider 协议、网络实现与 KeychainStore

**Files:**
- Modify: `Sources/ProjectDashboard/UsageProviders.swift`（追加协议与两个网络实现）
- Create: `Sources/ProjectDashboard/KeychainStore.swift`

**Interfaces:**
- Consumes: 两个 Parser、`UsageProviderID`、`ProviderUsageSummary`、`UsageFetchError`、`UsageSettings.glmInternationalKey`（Task 2/3 已定义）
- Produces（Task 5/6 依赖，签名精确如下）:
  - `protocol UsageProviding: Sendable { var id: UsageProviderID { get }; func fetchUsage(key: String) async throws -> ProviderUsageSummary }`
  - `struct KimiUsageProvider: UsageProviding`（无参 init）
  - `struct GLMUsageProvider: UsageProviding`（无参 init）
  - `protocol UsageKeyStore: Sendable { func readKey(for id: UsageProviderID) -> String?; func saveKey(_ key: String, for id: UsageProviderID); func deleteKey(for id: UsageProviderID) }`
  - `struct KeychainStore: UsageKeyStore`（默认 init，service `com.carlwang.ProjectDashboard.usage`）

- [ ] **Step 1: 在 UsageProviders.swift 末尾追加协议与网络实现**

在 `Sources/ProjectDashboard/UsageProviders.swift` 文件末尾追加：

```swift
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
            var data = try await get(path: "usages", key: key)
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
```

- [ ] **Step 2: 创建 KeychainStore.swift**

创建 `Sources/ProjectDashboard/KeychainStore.swift`：

```swift
import Foundation
import Security

/// API key 的存取接口（Task 5 的 UsageModel 依赖此协议注入测试替身）
protocol UsageKeyStore: Sendable {
    func readKey(for id: UsageProviderID) -> String?
    func saveKey(_ key: String, for id: UsageProviderID)
    func deleteKey(for id: UsageProviderID)
}

/// key 只存 Keychain，不落 UserDefaults、不写日志
struct KeychainStore: UsageKeyStore {
    private let service: String

    init(service: String = "com.carlwang.ProjectDashboard.usage") {
        self.service = service
    }

    func readKey(for id: UsageProviderID) -> String? {
        var query = baseQuery(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }

    func saveKey(_ key: String, for id: UsageProviderID) {
        let data = Data(key.utf8)
        let query = baseQuery(for: id)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    func deleteKey(for id: UsageProviderID) {
        SecItemDelete(baseQuery(for: id) as CFDictionary)
    }

    private func baseQuery(for id: UsageProviderID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.rawValue,
        ]
    }
}
```

- [ ] **Step 3: 编译确认（无网络代码的自动化测试，编译通过即结构正确）**

Run: `swift build && swift test`
Expected: 编译成功，既有测试全部通过

- [ ] **Step 4: Commit**

```bash
git add Sources/ProjectDashboard/UsageProviders.swift Sources/ProjectDashboard/KeychainStore.swift
git commit -m "feat: 用量查询 Provider 协议、Kimi/GLM 网络实现与 Keychain 存取"
```

---

### Task 5: UsageModel 状态编排（TDD，mock provider）

**Files:**
- Create: `Sources/ProjectDashboard/UsageModel.swift`
- Test: `Tests/ProjectDashboardTests/UsageModelTests.swift`

**Interfaces:**
- Consumes: `UsageProviding`、`UsageKeyStore`、`UsageState`、`ProviderUsageSummary`、`UsageProviderID`、`UsageFetchError`（前序任务已定义）
- Produces（Task 6 UI 依赖，签名精确如下）:
  - `@MainActor final class UsageModel: ObservableObject`
  - `@Published private(set) var states: [UsageProviderID: UsageState]`
  - `@Published private(set) var isRefreshing: Bool`
  - `@Published private(set) var configured: Set<UsageProviderID>`
  - `let providers: [any UsageProviding]`
  - `init(providers: [any UsageProviding] = [KimiUsageProvider(), GLMUsageProvider()], keyStore: any UsageKeyStore = KeychainStore())`
  - `func refreshIfNeeded() async`（节流 300 秒；面板 onAppear 用）
  - `func refreshNow() async`（强制刷新；手动 ⟳ 与保存 key 后用）
  - `func saveKey(_ key: String, for id: UsageProviderID)`
  - `func deleteKey(for id: UsageProviderID)`

- [ ] **Step 1: 写失败测试**

创建 `Tests/ProjectDashboardTests/UsageModelTests.swift`：

```swift
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
    func readKey(for id: UsageProviderID) -> String? { keys[id] }
    func saveKey(_ key: String, for id: UsageProviderID) { keys[id] = key }
    func deleteKey(for id: UsageProviderID) { keys[id] = nil }
}

// MARK: - 测试

@MainActor
struct UsageModelTests {
    private let okSummary = ProviderUsageSummary(usedPercent: 42, resetAt: nil)

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
}
```

- [ ] **Step 2: 运行测试确认编译失败**

Run: `swift test`
Expected: 编译失败，`cannot find 'UsageModel' in scope`

- [ ] **Step 3: 实现 UsageModel.swift**

创建 `Sources/ProjectDashboard/UsageModel.swift`：

```swift
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
        self.configured = Set(providers.map(\.id).filter { keyStore.readKey(for: $0) != nil })
        var initial: [UsageProviderID: UsageState] = [:]
        for id in providers.map(\.id) {
            // 已配置但未查询过：面板未打开时保持 loading 无副作用，
            // 首次 onAppear 会立即触发真实查询
            initial[id] = configured.contains(id) ? .loading : .unconfigured
        }
        self.states = initial
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

        // 先取好 key 再进并发组，避免在非隔离上下文触碰 MainActor 状态
        let configuredProviders: [(provider: any UsageProviding, key: String)] = providers
            .filter { configured.contains($0.id) }
            .compactMap { provider in
                keyStore.readKey(for: provider.id).map { (provider, $0) }
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
```

- [ ] **Step 4: 运行测试确认全部通过**

Run: `swift test`
Expected: 全部通过（前序 + 本任务 5 个测试）

- [ ] **Step 5: Commit**

```bash
git add Sources/ProjectDashboard/UsageModel.swift Tests/ProjectDashboardTests/UsageModelTests.swift
git commit -m "feat: UsageModel 用量状态编排（并行查询、节流、key 生命周期）"
```

---

### Task 6: UsageSectionView UI + 设置弹层 + 面板接线

**Files:**
- Create: `Sources/ProjectDashboard/UsageSectionView.swift`
- Modify: `Sources/ProjectDashboard/PanelView.swift:4-22`（注入 environmentObject、插入区块、调高面板、onAppear 刷新）
- Modify: `Sources/ProjectDashboard/ProjectDashboardApp.swift:6,14-16,27-29`（创建并注入 UsageModel）

**Interfaces:**
- Consumes: `UsageModel` 全部公开 API（Task 5 Produces 清单）、`UsageSettings.glmInternationalKey`（Task 2）
- Produces: `struct UsageSectionView: View`（无需外部参数，经 environmentObject 取数）

- [ ] **Step 1: 创建 UsageSectionView.swift（区块 UI + 设置弹层）**

创建 `Sources/ProjectDashboard/UsageSectionView.swift`：

```swift
import SwiftUI

/// 面板顶部的 Token 用量区块：每家一行进度条 + 手动刷新 + key 设置入口
struct UsageSectionView: View {
    @EnvironmentObject private var usage: UsageModel
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Text("Token 用量")
                    .font(.headline)
                Spacer()
                if usage.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    Task { await usage.refreshNow() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("立即刷新用量")
                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("配置 API Key")
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    UsageSettingsView()
                        .environmentObject(usage)
                        .frame(width: 320)
                }
            }
            ForEach(usage.providers, id: \.id) { provider in
                UsageProviderRow(
                    state: usage.states[provider.id] ?? .unconfigured,
                    name: provider.displayName
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// 单个提供商行：按状态展示 配置入口 / 加载中 / 失败 / 进度条
private struct UsageProviderRow: View {
    let state: UsageState
    let name: String

    var body: some View {
        switch state {
        case .unconfigured:
            HStack {
                Text(name).foregroundStyle(.secondary)
                Spacer()
                Text("未配置")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        case .loading:
            HStack {
                Text(name)
                Spacer()
                ProgressView().controlSize(.small)
            }
        case .failed(let message):
            HStack {
                Text(name)
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("获取失败")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .help(message)
        case .loaded(let summary):
            HStack(spacing: 8) {
                Text(name)
                UsageBar(percent: summary.usedPercent)
                Text("\(Int(summary.usedPercent.rounded()))%")
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
                Text(resetText(summary.resetAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .trailing)
            }
        }
    }

    /// 窗口重置倒计时文案；无重置时间或已过期则降级显示
    private func resetText(_ date: Date?) -> String {
        guard let date else { return "—" }
        let diff = date.timeIntervalSinceNow
        if diff <= 0 { return "重置中" }
        let hours = Int(diff) / 3600
        let minutes = Int(diff) % 3600 / 60
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h 后重置" }
        if hours >= 1 { return "\(hours)h \(minutes)m 后重置" }
        return "\(minutes)m 后重置"
    }
}

/// 用量进度条：< 50% 绿、50%–85% 黄、> 85% 红
private struct UsageBar: View {
    let percent: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color)
                    .frame(width: max(4, geo.size.width * percent / 100))
            }
        }
        .frame(height: 6)
    }

    private var color: Color {
        if percent > 85 { return .red }
        if percent >= 50 { return .yellow }
        return .green
    }
}

/// key 设置弹层：粘贴 key（存 Keychain）、GLM 域名切换、清除 key
private struct UsageSettingsView: View {
    @EnvironmentObject private var usage: UsageModel
    @State private var kimiKey = ""
    @State private var glmKey = ""
    @AppStorage(UsageSettings.glmInternationalKey) private var glmInternational = false

    var body: some View {
        Form {
            LabeledContent("Kimi") {
                VStack(alignment: .leading, spacing: 4) {
                    SecureField(statusText(.kimi), text: $kimiKey)
                    footer(for: .kimi)
                }
            }
            LabeledContent("GLM") {
                VStack(alignment: .leading, spacing: 4) {
                    SecureField(statusText(.glm), text: $glmKey)
                    Picker("接口域名", selection: $glmInternational) {
                        Text("国内版").tag(false)
                        Text("国际版").tag(true)
                    }
                    .pickerStyle(.segmented)
                    footer(for: .glm)
                }
            }
            HStack {
                Spacer()
                Button("保存并刷新") {
                    if !kimiKey.isEmpty { usage.saveKey(kimiKey, for: .kimi) }
                    if !glmKey.isEmpty { usage.saveKey(glmKey, for: .glm) }
                    kimiKey = ""
                    glmKey = ""
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    /// SecureField 占位符提示已配置状态与 key 前缀
    private func statusText(_ id: UsageProviderID) -> String {
        let hint = id == .kimi ? "sk-kimi-…" : "GLM API Key"
        return usage.configured.contains(id) ? "已配置，粘贴新值可替换（\(hint)）" : "粘贴 \(hint)"
    }

    @ViewBuilder
    private func footer(for id: UsageProviderID) -> some View {
        if usage.configured.contains(id) {
            HStack {
                Label("已配置", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Spacer()
                Button("清除", role: .destructive) {
                    usage.deleteKey(for: id)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }
}
```

- [ ] **Step 2: 修改 PanelView.swift 插入区块**

对 `Sources/ProjectDashboard/PanelView.swift` 做三处修改：

1. 在 `@State private var showDirectories = false` 之后新增一行：

```swift
    @EnvironmentObject private var usageModel: UsageModel
```

2. 将 body 中的 VStack 内容替换为（插入区块 + 调高面板）：

```swift
        VStack(spacing: 0) {
            header
            Divider()
            UsageSectionView()
            Divider()
            RepoListView(repos: model.repos, rootPath: model.rootPathsSummary)
            Divider()
            footer
        }
        .frame(width: 400, height: 560)
        .onAppear {
            model.startAutoRefresh()
            model.refresh()
            Task { await usageModel.refreshIfNeeded() }
        }
```

（原 `.frame(width: 400, height: 500)` 与 `.onAppear` 被替换，其余代码不动。）

- [ ] **Step 3: 修改 ProjectDashboardApp.swift 注入 UsageModel**

对 `Sources/ProjectDashboard/ProjectDashboardApp.swift` 做两处修改：

1. 在 `@StateObject private var model = DashboardModel()` 之后新增：

```swift
    @StateObject private var usageModel = UsageModel()
```

2. 两个 scene 的视图各追加一个 environmentObject（MenuBarExtra 与 Window 都要）：

```swift
            PanelView()
                .environmentObject(model)
                .environmentObject(usageModel)
```

```swift
            MainWindowView()
                .environmentObject(model)
                .environmentObject(usageModel)
```

（`MainWindowView` 内部不使用用量数据，但保持注入一致，避免将来加主窗口明细页时遗漏。）

- [ ] **Step 4: 编译并运行既有测试**

Run: `swift build && swift test`
Expected: 编译成功；全部既有测试通过

- [ ] **Step 5: 手动冒烟（无 key 路径）**

Run: `swift run`（启动菜单栏应用，点击菜单栏图标打开面板）
Expected: 面板 header 下方出现「Token 用量」区块，两行均显示「未配置」；⚙︎ 弹层可打开、可关闭；仓库列表其余功能不受影响。验证后退出应用（面板底部「退出」）。

- [ ] **Step 6: Commit**

```bash
git add Sources/ProjectDashboard/UsageSectionView.swift Sources/ProjectDashboard/PanelView.swift Sources/ProjectDashboard/ProjectDashboardApp.swift
git commit -m "feat: 面板 Token 用量区块与 key 设置弹层"
```

---

### Task 7: 沙盒联网 entitlement + 完整构建 + 手动验收

**Files:**
- Modify: `Entitlements.plist`

**Interfaces:**
- Consumes: 前序全部成果
- Produces: 可分发的 .app（含联网权限）

- [ ] **Step 1: Entitlements.plist 增加联网权限**

在 `Entitlements.plist` 的 `<dict>` 内、`com.apple.security.app-sandbox` 条目之后插入：

```xml
    <!-- 用量查询需要出站网络访问 -->
    <key>com.apple.security.network.client</key>
    <true/>
```

- [ ] **Step 2: 完整构建 .app**

Run: `./build-app.sh`
Expected: 输出 `==> 完成：ProjectDashboard.app`；codesign 成功（脚本自带开发证书优先逻辑）。若 `/Applications` 已有安装副本，脚本会自动同步。

- [ ] **Step 3: 运行全部自动化测试**

Run: `swift test`
Expected: 全部通过（累计约 17 个测试）

- [ ] **Step 4: 手动验收（需要用户提供两家真实 key，逐项确认）**

启动打包后的 `ProjectDashboard.app`，逐项验证并在每项打勾：

1. 打开面板 → 「Token 用量」区块显示 Kimi、GLM 两行「未配置」
2. ⚙︎ 打开设置 → 粘贴 Kimi key（`sk-kimi-` 开头）与 GLM key → 保存并刷新 → 两行变为进度条与百分比
3. Kimi 百分比与 https://www.kimi.com/code/console 网页数值一致
4. GLM 百分比与 https://open.bigmodel.cn 控制台「用量统计」一致（国际版用户切到国际版域名再验一次）
5. ⟳ 按钮立即刷新，spinner 短暂出现后恢复
6. Kimi 行的重置倒计时与网页显示的窗口重置时间一致
7. 断网 → ⟳ → 两行显示「获取失败」，hover 警告图标显示「网络请求失败，请检查网络连接」；恢复网络 → ⟳ → 恢复正常
8. 设置中清除两家 key → 行回到「未配置」
9. 关闭面板 5 分钟内重新打开 → 不发请求（表现为数据立即显示、无 spinner）；`log stream` 中无新的出站连接亦可为证
10. 退出并重启 app → key 仍在（Keychain 持久化）、打开面板自动刷新出数据
11. 原有功能回归：仓库列表、git 状态徽章、target 清理入口均正常

- [ ] **Step 5: Commit**

```bash
git add Entitlements.plist
git commit -m "feat: 沙盒增加出站联网权限，用量查询可用了"
```

- [ ] **Step 6: 清理调研临时文件**

```bash
rm -rf /tmp/usage-research
```

---

## 计划自审记录

- **Spec 覆盖**：4 个新文件（T2/T3/T4/T5/T6）、Keychain（T4/T6）、节流与未配置跳过（T5 测试覆盖）、进度条颜色阈值（T6）、GLM 域名切换（T4/T6）、401 中文提示（T2/T4/T5 测试）、entitlements（T7）、testTarget 与解析测试（T1/T2/T3）、手动验收清单含错误态/持久化/回归（T7）——全部有对应任务
- **占位符扫描**：无 TBD/TODO；所有代码步骤给出完整代码
- **类型一致性**：`refreshNow()`/`refreshIfNeeded()`/`saveKey(_:for:)`/`deleteKey(for:)`/`configured`/`states`/`providers` 在 T5 定义、T6 使用处一致；`UsageSettings.glmInternationalKey` 在 T2 定义、T4/T6 使用一致；`UsageFetchError` 各 case 在 T2 定义、T3/T4/T5 使用一致
