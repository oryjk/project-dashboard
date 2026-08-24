import Foundation

enum RepoStatus {
    case clean        // 工作区干净且全部已推送
    case uncommitted  // 有未提交的修改
    case unpushed     // 有未推送的提交
    case noRemote     // 没有配置远程仓库
}

struct GitRepo: Identifiable {
    let path: String
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var branch: String = ""
    var uncommittedCount = 0
    var unpushedCount = 0
    var hasRemote = false
    var lastCommitDate: Date?
    /// Rust 项目且 target 目录存在构建产物
    var hasRustTarget = false
    /// 是否是 Rust 项目（根目录有 Cargo.toml）
    var isRustProject = false
    /// monorepo 内的 Rust 子项目（子目录含 Cargo.toml）
    var subProjects: [SubProject] = []

    var status: RepoStatus {
        if uncommittedCount > 0 { return .uncommitted }
        if !hasRemote { return .noRemote }
        if unpushedCount > 0 { return .unpushed }
        return .clean
    }
}

/// 仓库内的 Rust 子项目（monorepo 支持）
struct SubProject: Identifiable {
    let path: String
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    /// target 目录存在构建产物
    var hasRustTarget = false
}

enum GitScanner {

    /// 并发扫描多个目录，合并结果后按最近提交时间倒序返回。
    static func scan(roots: [String]) -> [GitRepo] {
        // 每个目录写各自的 box，避免并发写同一个数组
        final class Box: @unchecked Sendable { var repos: [GitRepo] = [] }
        let boxes = roots.map { _ in Box() }
        DispatchQueue.concurrentPerform(iterations: roots.count) { i in
            boxes[i].repos = scan(root: roots[i])
        }
        return boxes.flatMap(\.repos)
            .sorted { ($0.lastCommitDate ?? .distantPast) > ($1.lastCommitDate ?? .distantPast) }
    }

    /// 扫描 root 目录下一层的所有 git 仓库，按最近提交时间倒序返回。
    static func scan(root: String) -> [GitRepo] {
        let rootURL = URL(fileURLWithPath: (root as NSString).expandingTildeInPath)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let repos = entries.filter(isGitRepo).map(inspect)
        return repos.sorted { ($0.lastCommitDate ?? .distantPast) > ($1.lastCommitDate ?? .distantPast) }
    }

    private static func isGitRepo(_ url: URL) -> Bool {
        // .git 可能是目录，也可能是 worktree/submodule 产生的文件，两者都算仓库
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    private static func inspect(_ url: URL) -> GitRepo {
        var repo = GitRepo(path: url.path)

        repo.branch = git(url.path, ["rev-parse", "--abbrev-ref", "HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let porcelain = git(url.path, ["status", "--porcelain"]) ?? ""
        repo.uncommittedCount = porcelain.isEmpty ? 0 : porcelain.split(separator: "\n").count

        let remotes = git(url.path, ["remote"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        repo.hasRemote = !remotes.isEmpty
        if repo.hasRemote {
            // 所有远程分支上都不存在的本地提交数，即“未推送”
            let out = git(url.path, ["rev-list", "--count", "HEAD", "--not", "--remotes"])
            repo.unpushedCount = Int(out?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        }

        if let ts = git(url.path, ["log", "-1", "--format=%ct"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let t = TimeInterval(ts) {
            repo.lastCommitDate = Date(timeIntervalSince1970: t)
        }

        // Rust 项目：Cargo.toml 存在；target/ 非空则有构建产物可清理。
        // 非空检查只取第一个条目，不遍历，避免拖慢周期扫描。
        let fm = FileManager.default
        if fm.fileExists(atPath: url.appendingPathComponent("Cargo.toml").path) {
            repo.isRustProject = true
            repo.hasRustTarget = hasNonEmptyDir(url.appendingPathComponent("target").path, fm)
        }

        // monorepo 支持：一层子目录里含 Cargo.toml 的视为 Rust 子项目
        repo.subProjects = scanSubProjects(of: url, fm)

        return repo
    }

    private static func hasNonEmptyDir(_ path: String, _ fm: FileManager) -> Bool {
        guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return false }
        return !entries.isEmpty
    }

    /// 扫描仓库一层子目录，找出含 Cargo.toml 的 Rust 子项目，按名称排序。
    private static func scanSubProjects(of url: URL, _ fm: FileManager) -> [SubProject] {
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var subs: [SubProject] = []
        for dir in entries {
            let name = dir.lastPathComponent
            // 跳过产物/依赖目录
            if name == "target" || name == "node_modules" { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard fm.fileExists(atPath: dir.appendingPathComponent("Cargo.toml").path) else { continue }
            subs.append(SubProject(
                path: dir.path,
                hasRustTarget: hasNonEmptyDir(dir.appendingPathComponent("target").path, fm)
            ))
        }
        return subs.sorted { $0.name < $1.name }
    }

    /// 沙盒下优先用 bundle 内的真实 git。
    /// 注意：/usr/bin/git 是 Xcode tool-shim，运行时会 spawn 真正 git 到
    /// /Applications/Xcode.app/...，该路径不在 App Sandbox 授权范围 → spawn 被拒 → 垫片 abort，
    /// 导致 hasRemote/lastCommitDate/uncommittedCount 全部失效（所有项目显示"无远程"）。
    /// 回退 /usr/bin/git 仅用于非沙盒的开发场景。
    private static let gitURL: URL = {
        if let bundled = Bundle.main.url(forResource: "git", withExtension: nil) {
            return bundled
        }
        return URL(fileURLWithPath: "/usr/bin/git")
    }()

    /// 运行 git 命令，成功时返回 stdout，失败返回 nil。
    private static func git(_ path: String, _ args: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = gitURL
        process.arguments = ["-C", path] + args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
