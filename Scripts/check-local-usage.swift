// swiftc -parse-as-library Sources/ProjectDashboard/{UsageProviders,LocalUsageParsers,LocalUsageProviders}.swift Scripts/check-local-usage.swift -o /tmp/check-local-usage
import Foundation

@main
struct CheckLocalUsage {
    static func main() async {
        for provider: any UsageProviding in [CodexUsageProvider(), ClaudeUsageProvider()] {
            do {
                let result = try await provider.fetchUsage(key: "")
                for window in result.windows {
                    print("\(provider.id.displayName): \(window.label) 已用 \(window.usedPercent)%，重置 \(window.resetAt?.description ?? "未知")")
                }
            } catch {
                print("\(provider.id.displayName): \(error.localizedDescription)")
            }
        }
    }
}
