import Foundation

let repos = GitScanner.scan(roots: ["/tmp/rust-scan-root"])
for r in repos {
    print("\(r.name): hasRustTarget=\(r.hasRustTarget)")
}
precondition(repos.count == 3, "应扫描到 3 个仓库")
precondition(repos.first { $0.name == "rust-clean-test" }?.hasRustTarget == true, "有产物的应为 true")
precondition(repos.first { $0.name == "rust-empty-target" }?.hasRustTarget == false, "空 target 应为 false")
precondition(repos.first { $0.name == "not-rust" }?.hasRustTarget == false, "非 Rust 应为 false")
print("全部断言通过")
