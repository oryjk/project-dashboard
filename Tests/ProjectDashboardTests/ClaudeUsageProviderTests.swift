import Foundation
import Testing
@testable import ProjectDashboard

struct ClaudeUsageProviderTests {
    @Test func unauthorizedResponseRereadsCLIRenewedCredential() async throws {
        let fixture = ClaudeRequestFixture(tokens: ["old-token", "renewed-token"], statuses: [401, 200])
        let provider = ClaudeUsageProvider(tokenReader: { fixture.readToken() }, requestData: { fixture.respond($0) })
        let result = try await provider.fetchUsage(key: "")
        #expect(result.windows.map(\.usedPercent) == [52, 14])
        #expect(fixture.authorizations == ["Bearer old-token", "Bearer renewed-token"])
    }

    @Test func unchangedUnauthorizedCredentialDoesNotClaimAccountLogoutOrRetryForever() async {
        let fixture = ClaudeRequestFixture(tokens: ["same-token"], statuses: [401])
        let provider = ClaudeUsageProvider(tokenReader: { fixture.readToken() }, requestData: { fixture.respond($0) })
        do {
            _ = try await provider.fetchUsage(key: "")
            Issue.record("Expected unavailable access token")
        } catch {
            #expect(!error.localizedDescription.contains("登录已"))
            #expect(!error.localizedDescription.contains("same-token"))
        }
        #expect(fixture.authorizations.count == 1)
    }

    @Test func forbiddenUsageIsDifferentFromExpiredLogin() async {
        let fixture = ClaudeRequestFixture(tokens: ["valid-token"], statuses: [403])
        let provider = ClaudeUsageProvider(tokenReader: { fixture.readToken() }, requestData: { fixture.respond($0) })
        do {
            _ = try await provider.fetchUsage(key: "")
            Issue.record("Expected denied usage access")
        } catch {
            #expect(error.localizedDescription.contains("用量查询"))
            #expect(!error.localizedDescription.contains("登录已"))
        }
        #expect(fixture.authorizations.count == 1)
    }
}

@MainActor
struct UsageFailureRecoveryTests {
    @Test func failedLocalAccountRetriesSoonWithoutRefetchingSuccessfulProviders() async {
        var date = Date(timeIntervalSince1970: 1792480000)
        let recovering = RecoveringUsageProvider()
        let summary = ProviderUsageSummary(windows: [UsageWindow(label: "周", usedPercent: 10, resetAt: nil)])
        let codex = MockProvider(id: .codex, result: .success(summary))
        let model = UsageModel(providers: [recovering, codex], keyStore: InMemoryKeyStore(), now: { date })
        await model.refreshIfNeeded()
        #expect(model.states[.claude] == .failed(UsageFetchError.network.localizedDescription))
        date = date.addingTimeInterval(10)
        await model.refreshIfNeeded()
        #expect(await recovering.attempts == 1)
        date = date.addingTimeInterval(21)
        await model.refreshIfNeeded()
        #expect(model.states[.claude] == .loaded(ProviderUsageSummary(windows: [UsageWindow(label: "5 小时", usedPercent: 52, resetAt: nil)])))
        #expect(codex.fetchCount == 1)
    }
}

private actor RecoveringUsageProvider: UsageProviding {
    nonisolated let id = UsageProviderID.claude
    private(set) var attempts = 0
    func fetchUsage(key: String) async throws -> ProviderUsageSummary {
        attempts += 1
        if attempts == 1 { throw UsageFetchError.network }
        return ProviderUsageSummary(windows: [UsageWindow(label: "5 小时", usedPercent: 52, resetAt: nil)])
    }
}

private final class ClaudeRequestFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let tokens: [String]
    private let statuses: [Int]
    private var reads = 0
    private var headers: [String] = []

    init(tokens: [String], statuses: [Int]) { self.tokens = tokens; self.statuses = statuses }
    var authorizations: [String] { lock.withLock { headers } }
    func readToken() -> String {
        lock.withLock {
            defer { reads += 1 }
            return tokens[min(reads, tokens.count - 1)]
        }
    }
    func respond(_ request: URLRequest) -> (Data, URLResponse) {
        lock.withLock {
            let status = statuses[min(headers.count, statuses.count - 1)]
            headers.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            let data = Data(#"{"five_hour":{"utilization":52,"resets_at":null},"seven_day":{"utilization":14,"resets_at":null}}"#.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}
