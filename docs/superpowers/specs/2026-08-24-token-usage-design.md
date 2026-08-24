# 设计：Token 用量聚合区块

日期：2026-08-24
状态：已与用户确认

## 背景与目标

用户订阅了 Kimi for Coding 和 GLM Coding Plan，平时需要分别登录两家网页控制台
（如 https://www.kimi.com/code/console）查看 token 用量。目标是在 my-dashboard
（macOS 菜单栏应用）中聚合展示两家的用量，打开面板即可看到，无需开浏览器。

范围决策（已确认）：

- 提供商：仅 Kimi 与 GLM 两家
- 展示位置：菜单栏下拉面板顶部区块（不新增主窗口页面）
- 展示粒度：每家一行的汇总进度条（已用百分比 + 重置倒计时），不做模型维度明细
- Key 配置：应用内粘贴，存 macOS Keychain
- 不做后台轮询；Kimi「月度会员额度」需浏览器扩展（WebBridge），本期不做

## 前置调研结论

两家都支持「纯 API Key + HTTP GET」查询用量，无需浏览器登录或 cookie。
端点均为网页控制台的内部接口（非正式公开 API），可能变更，解析需防御性容错。

### Kimi for Coding

- 端点：`GET https://api.kimi.com/coding/v1/usages`（404 时回退 `/usage`）
- 认证：`Authorization: Bearer {key}`，`User-Agent: KimiCLI/1.6`
  - key 必须是 Kimi Code 控制台创建的 `sk-kimi-` 前缀 key；
    开放平台（platform.kimi.com / api.moonshot.cn）的 key 无效（401）
- 响应：`data` 数组；`model_name == "all"` 的项为周用量汇总，
  其余项为各限额窗口。字段名有变体：`used`/`used_amount`、
  `limit`/`limit_amount`、`remaining`、`resetTime`/`reset_at`（ISO8601 或秒级时间戳）、`reset_in`
- 来源：开源项目 kimi-code-usage（GitHub: Golden0Voyager/kimi-code-usage）源码

### GLM Coding Plan（智谱）

- 端点（路径相同，域名二选一）：
  - 国内版：`https://open.bigmodel.cn`
  - 国际版：`https://api.z.ai`
  - `GET {domain}/api/monitor/usage/quota/limit`
- 认证：`Authorization: {key}`（无 Bearer 前缀），key 为 GLM Coding Plan 的 API key
- 响应：`limits` 数组；`type == "TOKENS_LIMIT"` 为 5 小时 Token 窗口
  （含 `percentage`）；`type == "TIME_LIMIT"` 为 MCP 月度用量。无重置时间字段
- 来源：智谱官方插件仓库 zai-org/zai-coding-plugins 的 glm-plan-usage 插件源码

## 架构

新增 4 个 Swift 文件，零第三方依赖，符合项目现状：

```
Sources/ProjectDashboard/
├── UsageModel.swift        # @MainActor ObservableObject，状态与刷新编排
├── UsageProviders.swift    # UsageProvider 协议 + Kimi/GLM 实现；解析为纯函数
├── UsageSectionView.swift  # 面板区块 UI + key 设置弹层
└── KeychainStore.swift     # Security framework 的 Keychain CRUD
```

`UsageModel` 独立于现有 `DashboardModel`（单一职责），在 App 入口创建并通过
`.environmentObject` 注入。`PanelView` 在 header 与 `RepoListView` 之间插入
`UsageSectionView`。

## 数据模型

```swift
struct ProviderUsageSummary {
    let usedPercent: Double   // 0...100，当前窗口已用百分比
    let resetAt: Date?        // 窗口重置时间；GLM 不提供则为 nil
}

enum UsageState {
    case unconfigured         // 未配置 key
    case loading
    case loaded(ProviderUsageSummary)
    case failed(String)       // 面向用户的中文错误信息
}
```

归一化规则：

- Kimi：取 `model_name == "all"` 行，`percent = used / limit * 100`，
  重置时间来自 `resetTime`（兼容时间戳与 ISO8601 两种格式）；
  `limit` 缺失或为 0 时该家进入 `failed("接口未返回限额信息")`
- GLM：取 `type == "TOKENS_LIMIT"` 的 `percentage`；`resetAt = nil`；
  找不到该类型时同样进入 failed

## Provider 协议与网络

```swift
protocol UsageProviding {
    var id: String { get }            // "kimi" / "glm"
    var displayName: String { get }   // "Kimi" / "GLM"
    func fetchUsage(key: String) async throws -> ProviderUsageSummary
}
```

- URLSession.shared，超时 10 秒，async/await
- 两家并行请求（`async let`），互不阻塞；一家失败不影响另一家
- 错误分类（中文提示）：
  - 401：key 无效或格式错误（Kimi 特别提示不要用开放平台的 `sk-` key）
  - 网络失败 / 超时：提示检查网络
  - JSON 结构不符：「接口返回格式变化，解析失败」
- GLM 域名（国内/国际）作为设置项存储于 UserDefaults（非敏感），
  key 本身只存 Keychain

## Key 管理（KeychainStore）

- `kSecClassGenericPassword`，service = `com.carlwang.ProjectDashboard.usage`，
  account = `kimi` / `glm`
- API：`read(account:) / save(account:, secret:) / delete(account:)`
- 设置弹层（popover）：两个 SecureField（占位符提示 key 前缀 `sk-kimi-`）、
  GLM 域名切换（默认 `open.bigmodel.cn`）、保存/清除按钮
- 保存后立即触发刷新；已配置的 key 不回显明文，只显示「已配置」状态
- key 不落 UserDefaults、不写日志

## UI（面板区块）

插在 header 与仓库列表之间，风格与现有 header 一致：

```
│ Token 用量                 ⟳   ⚙︎   │
│ Kimi   ▓▓▓▓▓▓▓░░░ 78%  3d 2h 后重置 │
│ GLM    ▓▓▓▓▓▓░░░░ 55%       —       │
```

- 进度条颜色（按已用百分比）：< 50% 绿色、50%–85% 黄色、> 85% 红色
- 未配置 key：该行显示「配置 API Key」按钮，点击弹出设置层
- 失败：行内红色警告图标，hover（help）显示错误详情，点击 ⟳ 重试
- 加载中：该行显示小型 ProgressView

## 刷新策略

- 面板 `onAppear` 自动刷新，节流：距上次刷新尝试（无论成败）< 5 分钟则跳过；
  未配置 key 的提供商不发起请求
- 区块内 ⟳ 按钮强制立即刷新（忽略节流，已配置的提供商都请求）

## 沙盒与构建

- `Entitlements.plist` 新增 `com.apple.security.network-client = true`
- `build-app.sh` / `release.sh` 流程不变（entitlements 文件改动自动生效）

## 测试

- `Package.swift` 新增 testTarget（Swift Testing 框架）
- 解析逻辑为纯函数，用真实样本 JSON 覆盖：
  - 标准响应（两家）
  - 字段名变体（Kimi 的 `used_amount`/`limit_amount`/`remaining`）
  - `resetTime` 的时间戳与 ISO8601 两种格式
  - 缺字段 / 结构变化 → 明确报错而非崩溃
- 网络层与 UI 不写自动化测试（个人工具，真实 key 手动验收）：
  配置 key → 打开面板 → 两家数据展示 → 拔网线验证错误态 → 清除 key 验证未配置态

## 风险

| 风险 | 应对 |
|---|---|
| 端点是内部接口，可能变更 | 解析防御性容错 + Provider 隔离，变更只改单个文件 |
| Kimi key 与开放平台 key 混淆 | 401 提示明确区分两种 key |
| GLM 国际版/国内版行为差异 | 域名可切换，默认国内版 |

## 明确不做（YAGNI）

- 主窗口用量明细页、模型维度明细、历史图表
- 后台定时轮询、菜单栏图标用量徽章
- Kimi 月度会员额度（需 WebBridge 浏览器扩展）
- 其他提供商（协议已抽象，将来加 Provider 即可）
