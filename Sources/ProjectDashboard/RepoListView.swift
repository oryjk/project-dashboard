import SwiftUI
import AppKit

/// 弹出目录选择器（可多选）并加入扫描目录
@MainActor
func chooseAndAddDirectories(model: DashboardModel) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    if panel.runModal() == .OK {
        model.addRoots(panel.urls)
    }
}

/// 清理 Rust 构建产物的确认流程（仓库行和 monorepo 子项目行共用）：
/// 优先用缓存大小（没有则后台现算），检测运行中的进程，弹确认框，确认后删除。
/// path 指向仓库或子项目根目录。
@MainActor
func confirmCleanRustTarget(model: DashboardModel, path: String, displayName: String) {
    NSApp.activate(ignoringOtherApps: true)
    let cached = model.rustTargetSizes[path]
    Task.detached {
        var size = cached
        if size == nil {
            size = model.rustTargetSize(path: path)
        }
        let running = model.processesRunning(in: path)
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "清理 \(displayName) 的构建产物？"
            var text = size.map { "将删除 target 目录（约 \($0)），下次 cargo build 会重新生成。" }
                ?? "将删除 target 目录，下次 cargo build 会重新生成。"
            if !running.isEmpty {
                text = "检测到该项目内有正在运行的进程（\(running.joined(separator: "、"))），清理可能中断正在进行的构建或运行。\n\n" + text
                alert.icon = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            }
            alert.informativeText = text
            alert.addButton(withTitle: "清理")
            alert.addButton(withTitle: "取消")
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                try model.cleanRustTarget(path: path)
            } catch {
                let errorAlert = NSAlert()
                errorAlert.messageText = "清理失败"
                errorAlert.informativeText = error.localizedDescription
                errorAlert.runModal()
            }
        }
    }
}

/// 仓库列表，菜单栏面板和主窗口共用。
/// 分为三个可折叠分区：置顶 / 项目 / 归档，默认全部展开。
struct RepoListView: View {
    let repos: [GitRepo]
    let rootPath: String
    @EnvironmentObject private var model: DashboardModel

    @State private var searchText = ""
    @State private var pinnedExpanded = true
    @State private var normalExpanded = true
    @State private var archivedExpanded = true

    private var query: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    /// 三个分区按关键字过滤后的结果
    private var pinned: [GitRepo] { filtered(model.pinnedRepos) }
    private var normal: [GitRepo] { filtered(model.normalRepos) }
    private var archived: [GitRepo] { filtered(model.archivedRepos) }
    private var noMatch: Bool {
        !query.isEmpty && pinned.isEmpty && normal.isEmpty && archived.isEmpty
    }

    private func filtered(_ list: [GitRepo]) -> [GitRepo] {
        guard !query.isEmpty else { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            content
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索项目名称", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if model.rootPaths.isEmpty {
            // 首次启动 / 没有扫描目录：引导用户添加
            ContentUnavailableView {
                Label("还没有扫描目录", systemImage: "folder.badge.plus")
            } description: {
                Text("添加包含 git 项目的文件夹，开始查看各个项目的状态")
            } actions: {
                Button("添加目录…") {
                    chooseAndAddDirectories(model: model)
                }
                .buttonStyle(.borderedProminent)
            }
        } else if model.isScanning && repos.isEmpty {
            // 首次扫描（还没有任何数据）时显示 loading，而不是空白页
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)
                Text("正在扫描项目…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if repos.isEmpty {
            ContentUnavailableView {
                Label("没有找到 git 仓库", systemImage: "folder.badge.questionmark")
            } description: {
                Text("在 \(rootPath) 下没有发现 git 项目")
            }
        } else if noMatch {
            ContentUnavailableView.search(text: query)
        } else {
            List {
                // 搜索时强制展开各分区，保证匹配结果可见
                if !pinned.isEmpty {
                    repoSection("置顶", systemImage: "pin.fill", section: .pinned,
                                repos: pinned, expanded: query.isEmpty ? $pinnedExpanded : .constant(true))
                }
                if !normal.isEmpty {
                    repoSection("项目", systemImage: "folder", section: .normal,
                                repos: normal, expanded: query.isEmpty ? $normalExpanded : .constant(true))
                }
                if !archived.isEmpty {
                    repoSection("归档", systemImage: "archivebox", section: .archived,
                                repos: archived, expanded: query.isEmpty ? $archivedExpanded : .constant(true))
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private func repoSection(_ title: String, systemImage: String, section: RepoSection,
                             repos: [GitRepo], expanded: Binding<Bool>) -> some View {
        DisclosureGroup(isExpanded: expanded) {
            ForEach(repos) { repo in
                RepoRow(repo: repo, section: section)
                    .listRowSeparator(.hidden)
            }
            // 分区底部的投放区域：拖到这里放到分区末尾
            Color.clear
                .frame(height: 14)
                .contentShape(Rectangle())
                .onDrop(of: [.text], delegate: RepoDropDelegate(section: section, targetPath: nil, model: model))
                .listRowSeparator(.hidden)
        } label: {
            HStack(spacing: 5) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                Text("\(repos.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .padding(.top, 6) // 分区之间用留白区分，替代分割线
            // 折叠状态下也可以拖到分区标题上（放到分区末尾）
            .onDrop(of: [.text], delegate: RepoDropDelegate(section: section, targetPath: nil, model: model))
        }
        .listRowSeparator(.hidden)
    }
}

/// 行 / 分区投放代理：落到行上半部分 = 插到该行之前，下半部分 = 插到该行之后；
/// 落到分区尾部/标题（targetPath 为 nil）= 放到分区末尾
private struct RepoDropDelegate: DropDelegate {
    let section: RepoSection
    let targetPath: String?
    var rowHeight: CGFloat = 0
    let model: DashboardModel

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func dropUpdated(info: DropInfo) -> DropProposal {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        // 按落点在目标行的上半/下半部分决定插入到之前还是之后
        let after = rowHeight > 0 && info.location.y > rowHeight / 2
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let path = obj as? String else { return }
            Task { @MainActor in
                self.model.transferRepo(path: path, to: self.section, target: self.targetPath, after: after)
            }
        }
        return true
    }
}

struct RepoRow: View {
    let repo: GitRepo
    let section: RepoSection
    @EnvironmentObject private var model: DashboardModel
    @State private var isHovered = false
    @State private var rowHeight: CGFloat = 0
    @State private var isExpanded = false

    private var pinned: Bool { model.isPinned(repo) }
    private var archived: Bool { model.isArchived(repo) }

    var body: some View {
        if repo.subProjects.isEmpty {
            rowContent
        } else {
            // monorepo：可展开查看子项目
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(repo.subProjects) { sub in
                    SubProjectRow(sub: sub)
                        // 子行没有 ⋯ 菜单，补偿其占位让子行徽章右缘与父行对齐。
                        // 30 为实测对齐值（菜单占位约 34pt，DisclosureGroup
                        // 子行比 label 行多出约 4pt 尾部内边距）
                        .padding(.trailing, 30)
                }
            } label: {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .help(statusText)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(repo.name)
                        .font(.system(.body, weight: .medium))
                    if pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("已置顶")
                    }
                }
                HStack(spacing: 6) {
                    Label(repo.branch, systemImage: "arrow.triangle.branch")
                    Text("·")
                    if let date = repo.lastCommitDate {
                        Text(date, style: .relative)
                    } else {
                        Text("暂无提交")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            badges

            // 行尾操作区：⋯ 菜单，悬停显现
            actionMenu
                .opacity(isHovered ? 1 : 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle()) // 让整行（含空白区域）都可响应拖拽、投放和右键
        .opacity(archived ? 0.55 : 1) // 归档的项目淡显
        .onHover { isHovered = $0 }
        .contextMenu { menuItems }
        // 拖拽：可拖动，也可作为投放目标（上半部分插到本行前，下半部分插到本行后，支持跨分区）
        .onDrag {
            NSItemProvider(object: repo.path as NSString)
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { rowHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, newHeight in rowHeight = newHeight }
            }
        )
        .onDrop(of: [.text], delegate: RepoDropDelegate(section: section, targetPath: repo.path,
                                                        rowHeight: rowHeight, model: model))
    }

    /// 悬停时显示的“⋯”按钮，点开是操作菜单（悬停显隐由外层操作区统一控制）
    private var actionMenu: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private var menuItems: some View {
        Button(pinned ? "取消置顶" : "置顶") {
            model.togglePin(repo)
        }
        Divider()
        Button("在 Finder 中显示") {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: repo.path)
        }
        Button("在终端中打开") {
            NSWorkspace.shared.open(URL(fileURLWithPath: repo.path))
        }
        Divider()
        Button(archived ? "从归档恢复" : "移除") {
            model.toggleArchive(repo)
        }
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 6) {
            if repo.uncommittedCount > 0 {
                Badge(text: "\(repo.uncommittedCount) 未提交", color: .orange)
            }
            if !repo.hasRemote {
                Badge(text: "无远程", color: .gray)
            } else if repo.unpushedCount > 0 {
                Badge(text: "\(repo.unpushedCount) 未推送", color: .blue)
            }
            if repo.isRustProject {
                if repo.hasRustTarget {
                    // 点击徽章直接触发清理
                    Button {
                        confirmCleanRustTarget(model: model, path: repo.path, displayName: repo.name)
                    } label: {
                        Badge(text: "\(model.rustTargetSizes[repo.path] ?? "…") 可清理", color: .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("点击清理 Rust 构建产物（target 目录）")
                } else {
                    Badge(text: "无需清理", color: .green)
                }
            }
        }
    }

    private var statusColor: Color {
        switch repo.status {
        case .clean: return .green
        case .uncommitted: return .orange
        case .unpushed: return .blue
        case .noRemote: return .gray
        }
    }

    private var statusText: String {
        switch repo.status {
        case .clean: return "干净，已全部推送"
        case .uncommitted: return "有未提交的修改"
        case .unpushed: return "有未推送的提交"
        case .noRemote: return "没有远程仓库"
        }
    }
}

/// monorepo 子项目行：只提供构建产物清理，不参与置顶/归档/拖拽
struct SubProjectRow: View {
    let sub: SubProject
    @EnvironmentObject private var model: DashboardModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cube")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 10)

            Text(sub.name)
                .font(.callout)

            Spacer()

            // 子项目都是 Rust 项目：有产物显示可点击的可清理徽章，否则显示无需清理
            if sub.hasRustTarget {
                Button {
                    confirmCleanRustTarget(model: model, path: sub.path, displayName: sub.name)
                } label: {
                    Badge(text: "\(model.rustTargetSizes[sub.path] ?? "…") 可清理", color: .secondary)
                }
                .buttonStyle(.plain)
                .help("点击清理 Rust 构建产物（target 目录）")
            } else {
                Badge(text: "无需清理", color: .green)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button("在 Finder 中显示") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: sub.path)
            }
            Button("在终端中打开") {
                NSWorkspace.shared.open(URL(fileURLWithPath: sub.path))
            }
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .lineLimit(1)
            .fixedSize() // 窄面板下也不换行，保持胶囊形状
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
