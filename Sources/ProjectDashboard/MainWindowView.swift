import SwiftUI
import AppKit

/// 正常应用形态的主窗口：点击菜单栏面板里的“打开主窗口”后显示
struct MainWindowView: View {
    @EnvironmentObject private var model: DashboardModel

    var body: some View {
        RepoListView(repos: model.repos, rootPath: model.rootPathsSummary)
            .frame(minWidth: 560, minHeight: 400)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        chooseDirectories()
                    } label: {
                        Label("添加目录", systemImage: "folder.badge.plus")
                    }
                    .help("添加扫描目录")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.refresh(invalidateSizes: true)
                    } label: {
                        if model.isScanning {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                    }
                    .help("刷新")
                }
            }
            .onAppear {
                // 窗口打开期间作为普通应用出现在 Dock
                NSApp.setActivationPolicy(.regular)
                model.startAutoRefresh()
                model.refresh()
            }
            .onDisappear {
                // 窗口关闭后恢复为纯菜单栏应用
                NSApp.setActivationPolicy(.accessory)
            }
    }

    private func chooseDirectories() {
        chooseAndAddDirectories(model: model)
    }
}
