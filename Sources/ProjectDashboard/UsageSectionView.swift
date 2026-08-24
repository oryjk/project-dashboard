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
                    name: provider.id.displayName,
                    onConfigure: { showSettings = true }
                )
            }
            // 刷新状态行：上次更新时间 + 距下次自动刷新的倒计时（每秒驱动重算）
            if !usage.configured.isEmpty, let last = usage.lastRefreshAttempt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, UsageModel.throttleInterval - context.date.timeIntervalSince(last))
                    HStack(spacing: 4) {
                        Text("更新于 \(last, format: .dateTime.hour().minute().second())")
                        Text(remaining <= 0 ? "· 即将刷新…" : "· \(formatCountdown(remaining)) 后自动刷新")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 秒数格式化为 m:ss（节流窗口最大 300 秒）
    private func formatCountdown(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}

/// 单个提供商行：按状态展示 配置入口 / 加载中 / 失败 / 各限额窗口进度条
private struct UsageProviderRow: View {
    let state: UsageState
    let name: String
    /// 未配置行点击「配置 API Key」后打开 key 设置弹层
    let onConfigure: () -> Void

    var body: some View {
        switch state {
        case .unconfigured:
            HStack {
                Text(name).foregroundStyle(.secondary)
                Spacer()
                Button("配置 API Key", action: onConfigure)
                    .buttonStyle(.borderless)
                    .font(.caption)
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
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                // 每个限额窗口一行：窗口名 + 进度条 + 百分比 + 倒计时
                ForEach(summary.windows.indices, id: \.self) { index in
                    let window = summary.windows[index]
                    HStack(spacing: 8) {
                        Text(window.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .leading)
                        UsageBar(percent: window.usedPercent)
                        Text("\(Int(window.usedPercent.rounded()))%")
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                        // 倒计时每秒跳动：仅该 Text 被时间线驱动局部重绘，不触发整行刷新
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(resetText(window.resetAt, now: context.date))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 96, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    /// 窗口重置倒计时文案；无重置时间或已过期则降级显示。
    /// now 由 TimelineView 每秒传入（而非取 timeIntervalSinceNow），驱动倒计时跳动
    private func resetText(_ date: Date?, now: Date) -> String {
        guard let date else { return "—" }
        let diff = date.timeIntervalSince(now)
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

    /// 单列分区布局：所有元素共享同一左边缘（弹层宽度由调用处 .frame(width: 320) 统一约束）
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Kimi").font(.headline)
                    Spacer()
                    headerStatus(for: .kimi)
                }
                SecureField(statusText(.kimi), text: $kimiKey)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("GLM").font(.headline)
                    Spacer()
                    headerStatus(for: .glm)
                }
                SecureField(statusText(.glm), text: $glmKey)
                Text("接口域名")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("接口域名", selection: $glmInternational) {
                    Text("国内版").tag(false)
                    Text("国际版").tag(true)
                }
                .pickerStyle(.segmented)
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
        .padding(12)
    }

    /// SecureField 占位符提示已配置状态与 key 前缀
    private func statusText(_ id: UsageProviderID) -> String {
        let hint = id == .kimi ? "sk-kimi-…" : "GLM API Key"
        return usage.configured.contains(id) ? "已配置，粘贴新值可替换（\(hint)）" : "粘贴 \(hint)"
    }

    /// 分区头部右侧状态：已配置显示绿勾 + 清除按钮，未配置显示灰字
    @ViewBuilder
    private func headerStatus(for id: UsageProviderID) -> some View {
        if usage.configured.contains(id) {
            Label("已配置", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
            Button("清除", role: .destructive) {
                usage.deleteKey(for: id)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        } else {
            Text("未配置")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
