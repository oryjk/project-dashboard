import SwiftUI
import AppKit

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
                .disabled(usage.isRefreshing)
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
                    usesLocalAccount: provider.id.usesLocalAccount,
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
    let usesLocalAccount: Bool
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
                providerName
                Spacer()
                ProgressView().controlSize(.small)
            }
        case .failed(let message):
            HStack {
                providerName
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("获取失败")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .help(message)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .loaded(let summary):
            VStack(alignment: .leading, spacing: 2) {
                providerName
                // 每个限额窗口一行：窗口名 + 进度条 + 百分比 + 倒计时
                ForEach(summary.windows.indices, id: \.self) { index in
                    let window = summary.windows[index]
                    HStack(spacing: 8) {
                        Text(window.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .leading)
                            .lineLimit(1)
                            .help(window.label)
                        UsageBar(percent: window.usedPercent)
                        Text("\(Int(window.usedPercent.rounded()))%")
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                            .help("已用 \(Int(window.usedPercent.rounded()))%，剩余 \(Int((100 - window.usedPercent).rounded()))%")
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

    private var providerName: some View {
        HStack(spacing: 5) {
            Text(name)
            if usesLocalAccount {
                Text("本机账号").font(.caption2).foregroundStyle(.secondary)
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
    @State private var copiedProvider: UsageProviderID?
    @AppStorage(UsageSettings.glmInternationalKey) private var glmInternational = false

    /// 单列分区布局：所有元素共享同一左边缘（弹层宽度由调用处 .frame(width: 320) 统一约束）
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("本机订阅账号").font(.headline)
                Text("Codex (GPT) 与 Claude Code 自动使用本机登录，无需 API Key。请先在终端完成对应账号登录。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("刷新本机额度") { Task { await usage.refreshNow() } }
                    .disabled(usage.isRefreshing)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Kimi").font(.headline)
                    Spacer()
                    headerStatus(for: .kimi)
                }
                keyInput(for: .kimi, text: $kimiKey)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("GLM").font(.headline)
                    Spacer()
                    headerStatus(for: .glm)
                }
                keyInput(for: .glm, text: $glmKey)
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
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .onAppear {
            kimiKey = usage.savedKey(for: .kimi) ?? ""
            glmKey = usage.savedKey(for: .glm) ?? ""
        }
        .onDisappear {
            kimiKey = ""
            glmKey = ""
            copiedProvider = nil
        }
    }

    /// SecureField 禁止原生复制；通过明确的按钮复制当前完整值，保留隐藏显示。
    private func keyInput(for id: UsageProviderID, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            SecureField(statusText(id), text: text)
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                copiedProvider = pasteboard.setString(text.wrappedValue, forType: .string) ? id : nil
            } label: {
                Label(copiedProvider == id ? "已复制" : "复制",
                      systemImage: copiedProvider == id ? "checkmark" : "doc.on.doc")
                    .fixedSize()
            }
            .buttonStyle(.borderless)
            .disabled(text.wrappedValue.isEmpty)
            .help("复制完整的 \(id.displayName) API Key")
            .accessibilityLabel("复制 \(id.displayName) API Key")
        }
        .onChange(of: text.wrappedValue) { _, _ in
            if copiedProvider == id { copiedProvider = nil }
        }
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
                if id == .kimi { kimiKey = "" }
                if id == .glm { glmKey = "" }
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
