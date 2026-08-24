import SwiftUI
import AppKit

struct PanelView: View {
    @EnvironmentObject private var model: DashboardModel
    @Environment(\.openWindow) private var openWindow
    @State private var showDirectories = false
    @EnvironmentObject private var usageModel: UsageModel

    var body: some View {
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
            usageModel.startPeriodicRefresh()
            Task { await usageModel.refreshIfNeeded() }
        }
        .onDisappear {
            usageModel.stopPeriodicRefresh()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("项目面板")
                    .font(.headline)
                Text(model.rootPathsSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if model.isScanning {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                model.refresh(invalidateSizes: true)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("刷新")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("打开主窗口") {
                openMainWindow()
            }
            .buttonStyle(.borderless)

            Button("目录…") {
                showDirectories.toggle()
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showDirectories, arrowEdge: .bottom) {
                DirectoryListView()
                    .environmentObject(model)
            }

            Spacer()

            if let date = model.lastScanDate {
                Text("更新于 \(date, style: .time)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func openMainWindow() {
        // 打开主窗口时切换为普通应用（出现在 Dock），并置前
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
