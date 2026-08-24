import Foundation

/// 列表的三个分区
enum RepoSection: String {
    case pinned, normal, archived
}

@MainActor
final class DashboardModel: ObservableObject {
    @Published var repos: [GitRepo] = []
    @Published var isScanning = false
    @Published var lastScanDate: Date?
    /// 扫描目录列表（从持久化的 security-scoped bookmark 解析得到）
    @Published private(set) var rootPaths: [String] = []
    /// 扫描目录的安全范围 bookmark，持久化到 UserDefaults（沙盒下重启后仍有访问权）
    private var rootBookmarks: [Data] {
        didSet { UserDefaults.standard.set(rootBookmarks, forKey: Self.rootBookmarksKey) }
    }
    /// 持有安全范围访问权的 URL（进程存续期间保持访问）
    private var accessingURLs: [URL] = []
    /// 置顶仓库的路径集合，持久化到 UserDefaults
    @Published private(set) var pinnedPaths: Set<String> {
        didSet { UserDefaults.standard.set(Array(pinnedPaths), forKey: Self.pinnedKey) }
    }
    /// 归档仓库的路径集合，持久化到 UserDefaults
    @Published private(set) var archivedPaths: Set<String> {
        didSet { UserDefaults.standard.set(Array(archivedPaths), forKey: Self.archivedKey) }
    }
    /// 各分区内用户拖拽自定义的顺序（分区 key → 有序路径数组），持久化到 UserDefaults
    @Published private(set) var sectionOrders: [String: [String]] {
        didSet {
            if let data = try? JSONEncoder().encode(sectionOrders) {
                UserDefaults.standard.set(data, forKey: Self.sectionOrdersKey)
            }
        }
    }

    private static let rootBookmarksKey = "scanRootBookmarks"
    private static let pinnedKey = "pinnedRepoPaths"
    private static let archivedKey = "archivedRepoPaths"
    private static let sectionOrdersKey = "sectionOrders"
    private var timer: Timer?
    /// 扫描代数：清理操作会递增，用于丢弃删除前启动的过期扫描结果
    private var scanGeneration = 0

    /// 有未提交 / 未推送 / 无远程的仓库数量（归档的不计入）
    var dirtyCount: Int {
        repos.filter { $0.status != .clean && !archivedPaths.contains($0.path) }.count
    }

    /// 界面上展示的目录摘要
    var rootPathsSummary: String {
        if rootPaths.count == 1 { return rootPaths[0] }
        return "\(rootPaths.count) 个目录"
    }

    init() {
        self.rootBookmarks = UserDefaults.standard.array(forKey: Self.rootBookmarksKey) as? [Data] ?? []
        // 从 bookmark 恢复目录授权
        var paths: [String] = []
        var refreshedBookmarks: [Data] = []
        for data in rootBookmarks {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data,
                                     options: .withSecurityScope,
                                     bookmarkDataIsStale: &stale) else { continue }
            if url.startAccessingSecurityScopedResource() {
                accessingURLs.append(url)
            }
            paths.append(url.path)
            // bookmark 过期时重建
            if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope) {
                refreshedBookmarks.append(fresh)
            } else {
                refreshedBookmarks.append(data)
            }
        }
        self.rootPaths = paths
        if refreshedBookmarks != rootBookmarks {
            self.rootBookmarks = refreshedBookmarks
        }
        self.pinnedPaths = Set(UserDefaults.standard.stringArray(forKey: Self.pinnedKey) ?? [])
        self.archivedPaths = Set(UserDefaults.standard.stringArray(forKey: Self.archivedKey) ?? [])
        if let data = UserDefaults.standard.data(forKey: Self.sectionOrdersKey),
           let saved = try? JSONDecoder().decode([String: [String]].self, from: data) {
            self.sectionOrders = saved
        } else {
            self.sectionOrders = [:]
        }
    }

    // MARK: - 目录管理

    /// 添加扫描目录（来自 NSOpenPanel 的授权 URL），创建 bookmark 持久化授权
    func addRoots(_ urls: [URL]) {
        var changed = false
        for url in urls {
            guard !rootPaths.contains(url.path) else { continue }
            guard let data = try? url.bookmarkData(options: .withSecurityScope) else { continue }
            if url.startAccessingSecurityScopedResource() {
                accessingURLs.append(url)
            }
            rootBookmarks.append(data)
            rootPaths.append(url.path)
            changed = true
        }
        if changed { refresh() }
    }

    func removeRoot(_ path: String) {
        guard let index = rootPaths.firstIndex(of: path) else { return }
        // 释放该目录的安全范围访问权
        if let i = accessingURLs.firstIndex(where: { $0.path == path }) {
            accessingURLs[i].stopAccessingSecurityScopedResource()
            accessingURLs.remove(at: i)
        }
        rootPaths.remove(at: index)
        rootBookmarks.remove(at: index)
        // 立即移除该目录下的仓库，不必等下次扫描
        let expanded = (path as NSString).expandingTildeInPath
        repos.removeAll { $0.path.hasPrefix(expanded + "/") }
    }

    // MARK: - 分层列表

    /// 三个分区：置顶、普通、归档。
    /// 优先按用户拖拽保存的顺序排列，没有自定义顺序的按最近提交时间倒序排在后面。
    var pinnedRepos: [GitRepo] { ordered(.pinned, from: repos.filter { pinnedPaths.contains($0.path) }) }
    var normalRepos: [GitRepo] { ordered(.normal, from: repos.filter { !pinnedPaths.contains($0.path) && !archivedPaths.contains($0.path) }) }
    var archivedRepos: [GitRepo] { ordered(.archived, from: repos.filter { archivedPaths.contains($0.path) }) }

    private func ordered(_ section: RepoSection, from candidates: [GitRepo]) -> [GitRepo] {
        let saved = sectionOrders[section.rawValue] ?? []
        var remaining = candidates
        var picked: [GitRepo] = []
        for path in saved {
            if let i = remaining.firstIndex(where: { $0.path == path }) {
                picked.append(remaining.remove(at: i))
            }
        }
        return picked + byDate(remaining)
    }

    /// 拖放移动：把项目移动到目标分区。
    /// targetPath 为落点行：after=false 插到它之前，after=true 插到它之后；nil 表示放到分区末尾。
    /// 跨分区拖放时同时更新归属（置顶 / 普通 / 归档）。
    func transferRepo(path: String, to section: RepoSection, target targetPath: String?, after: Bool = false) {
        // 落点就是自身（拖回原位松手）：不做任何操作
        if path == targetPath { return }
        // 1. 更新归属
        switch section {
        case .pinned:
            pinnedPaths.insert(path)
            archivedPaths.remove(path)
        case .normal:
            pinnedPaths.remove(path)
            archivedPaths.remove(path)
        case .archived:
            archivedPaths.insert(path)
            pinnedPaths.remove(path)
        }
        // 2. 更新顺序：先从所有分区的顺序表中移除，再插入目标位置
        for key in sectionOrders.keys {
            sectionOrders[key]?.removeAll { $0 == path }
        }
        var list: [String]
        switch section {
        case .pinned: list = pinnedRepos.map(\.path)
        case .normal: list = normalRepos.map(\.path)
        case .archived: list = archivedRepos.map(\.path)
        }
        list.removeAll { $0 == path }
        if let targetPath, let i = list.firstIndex(of: targetPath) {
            list.insert(path, at: after ? i + 1 : i)
        } else {
            list.append(path)
        }
        sectionOrders[section.rawValue] = list
    }

    private func byDate(_ list: [GitRepo]) -> [GitRepo] {
        list.sorted { ($0.lastCommitDate ?? .distantPast) > ($1.lastCommitDate ?? .distantPast) }
    }

    // MARK: - 置顶 / 归档

    func isPinned(_ repo: GitRepo) -> Bool {
        pinnedPaths.contains(repo.path)
    }

    func isArchived(_ repo: GitRepo) -> Bool {
        archivedPaths.contains(repo.path)
    }

    func togglePin(_ repo: GitRepo) {
        if pinnedPaths.contains(repo.path) {
            pinnedPaths.remove(repo.path)
        } else {
            pinnedPaths.insert(repo.path)
            archivedPaths.remove(repo.path) // 置顶与归档互斥
        }
    }

    func toggleArchive(_ repo: GitRepo) {
        if archivedPaths.contains(repo.path) {
            archivedPaths.remove(repo.path)
        } else {
            archivedPaths.insert(repo.path)
            pinnedPaths.remove(repo.path) // 置顶与归档互斥
        }
    }

    // MARK: - Rust 构建产物清理

    /// target 目录大小缓存（仓库路径 → 可读大小如 "3.9G"），按需后台计算
    @Published private(set) var rustTargetSizes: [String: String] = [:]
    private var sizeRequestsInFlight: Set<String> = []

    /// 请求计算 target 大小；已缓存或计算中的跳过。path 指向仓库或子项目根目录。
    func requestRustTargetSize(path: String) {
        guard rustTargetSizes[path] == nil,
              !sizeRequestsInFlight.contains(path) else { return }
        sizeRequestsInFlight.insert(path)
        Task.detached {
            let size = self.rustTargetSize(path: path)
            await MainActor.run {
                // du 失败（如目录刚被删掉）不缓存，避免显示 "?"
                if let size {
                    self.rustTargetSizes[path] = size
                }
                self.sizeRequestsInFlight.remove(path)
            }
        }
    }

    /// target 目录的可读大小（如 "3.9G"），失败返回 nil。
    /// 用 du 而不是 FileManager 遍历：大目录上快得多。非 MainActor，请在后台线程调用。
    nonisolated func rustTargetSize(path: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sh", path + "/target"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // du 在个别子目录读不了时会以非零码退出，但总量通常已输出，照常解析
        guard let out = String(data: data, encoding: .utf8), !out.isEmpty else { return nil }
        return out.split(separator: "\t").first?.trimmingCharacters(in: .whitespaces)
    }

    /// 检测工作目录位于该路径内的进程名（去重），用于清理前的友好提示。
    /// 非 MainActor，请在后台线程调用。
    nonisolated func processesRunning(in path: String) -> [String] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-d", "cwd", "-Fpcn"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return [] }

        // -Fpcn 输出：p<pid> / c<命令名> / n<cwd 路径> 逐行
        var names = Set<String>()
        var command = ""
        for line in out.split(separator: "\n") {
            switch line.first {
            case "c":
                command = String(line.dropFirst())
            case "n":
                let cwd = String(line.dropFirst())
                if (cwd == path || cwd.hasPrefix(path + "/")),
                   !command.isEmpty, command != "ProjectDashboard" {
                    names.insert(command)
                }
            default:
                break
            }
        }
        return names.sorted()
    }

    /// 删除 target 目录并触发刷新（按钮随之隐藏）。选 rm 而非 cargo clean：不依赖 cargo 是否安装。
    /// 首次删除失败时（可能混入只读/锁定文件），修复权限后重试一次；再失败抛出带详情的错误。
    /// path 指向仓库或子项目根目录。
    func cleanRustTarget(path: String) throws {
        let target = path + "/target"
        do {
            try FileManager.default.removeItem(atPath: target)
        } catch {
            Self.runSilently("/usr/bin/chflags", ["-R", "nouchg", target])
            Self.runSilently("/bin/chmod", ["-R", "u+w", target])
            do {
                try FileManager.default.removeItem(atPath: target)
            } catch let error as NSError {
                // 带上底层错误和具体失败路径，便于定位
                let path = error.userInfo[NSFilePathErrorKey] as? String ?? target
                let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError)
                    .map { "\n底层错误：\($0.domain) \($0.code)" } ?? ""
                throw NSError(domain: "ProjectDashboard", code: error.code, userInfo: [
                    NSLocalizedDescriptionKey: "无法删除：\(path)\n\(error.localizedDescription)\(underlying)"
                ])
            }
        }
        rustTargetSizes.removeValue(forKey: path)
        // 作废可能正在进行的扫描（其结果收集于删除之前，是过期数据），
        // 并立即更新当前列表状态，不等下次扫描
        scanGeneration += 1
        if let i = repos.firstIndex(where: { $0.path == path }) {
            repos[i].hasRustTarget = false
        }
        for i in repos.indices {
            if let j = repos[i].subProjects.firstIndex(where: { $0.path == path }) {
                repos[i].subProjects[j].hasRustTarget = false
            }
        }
        refresh()
    }

    /// 静默执行一个命令，忽略结果（用于权限修复的尽力而为操作）
    nonisolated private static func runSilently(_ path: String, _ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {}
    }

    // MARK: - 扫描

    func startAutoRefresh(interval: TimeInterval = 30) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// invalidateSizes=true 时清空 target 大小缓存并重新统计（用于手动刷新；
    /// 30 秒定时刷新走默认值，du 全量统计约 12 秒，不做）
    func refresh(invalidateSizes: Bool = false) {
        guard !isScanning else { return }
        let roots = rootPaths
        guard !roots.isEmpty else {
            repos = []
            return
        }
        if invalidateSizes { rustTargetSizes.removeAll() }
        isScanning = true
        let generation = scanGeneration
        Task.detached {
            let result = GitScanner.scan(roots: roots)
            await MainActor.run {
                // 扫描期间发生过清理：结果是删除前收集的过期数据，丢弃并重新扫描
                guard generation == self.scanGeneration else {
                    self.isScanning = false
                    self.refresh()
                    return
                }
                self.repos = result
                self.isScanning = false
                self.lastScanDate = Date()
                // 为缺大小的可清理目标（仓库自身 + monorepo 子项目）补算，
                // 后台 du，已缓存/计算中的自动跳过
                for repo in result {
                    if repo.hasRustTarget {
                        self.requestRustTargetSize(path: repo.path)
                    }
                    for sub in repo.subProjects where sub.hasRustTarget {
                        self.requestRustTargetSize(path: sub.path)
                    }
                }
            }
        }
    }
}
