import SwiftUI
import AppKit

@main
struct ProjectDashboardApp: App {
    @StateObject private var model = DashboardModel()

    init() {
        // 纯菜单栏应用，不出现在 Dock
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(model)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "folder.badge.gearshape")
                if model.dirtyCount > 0 {
                    Text("\(model.dirtyCount)")
                }
            }
        }
        .menuBarExtraStyle(.window)

        Window("项目面板", id: "main") {
            MainWindowView()
                .environmentObject(model)
        }
        .defaultSize(width: 700, height: 520)
    }
}
