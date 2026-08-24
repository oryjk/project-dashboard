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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
                        Text(resetText(window.resetAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 96, alignment: .trailing)
                    }
                }
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
