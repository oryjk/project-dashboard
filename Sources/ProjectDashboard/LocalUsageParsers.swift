import Foundation
import CoreFoundation

/// Missing values must never become a misleading zero-percent allowance.
private func percentage(_ value: Any?) throws -> Double {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
        throw UsageFetchError.parsing
    }
    return min(max(number.doubleValue, 0), 100)
}

enum CodexUsageParser {
    static func parse(_ data: Data) throws -> ProviderUsageSummary {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageFetchError.parsing
        }
        var buckets: [(String, [String: Any])] = []
        if let byID = root["rateLimitsByLimitId"] as? [String: [String: Any]], !byID.isEmpty {
            for id in byID.keys.sorted(by: { ($0 == "codex" ? "" : $0) < ($1 == "codex" ? "" : $1) }) {
                let bucket = byID[id]!
                buckets.append((id == "codex" ? "" : (bucket["limitName"] as? String ?? id), bucket))
            }
        } else if let legacy = root["rateLimits"] as? [String: Any] {
            buckets = [("", legacy)]
        }
        var windows: [UsageWindow] = []
        for (name, bucket) in buckets {
            for key in ["primary", "secondary"] {
                guard let window = bucket[key] as? [String: Any] else { continue }
                guard let mins = window["windowDurationMins"] as? Int, mins > 0 else {
                    throw UsageFetchError.parsing
                }
                let label: String
                if mins == 10080 { label = "周" }
                else if mins % 1440 == 0 { label = "\(mins / 1440) 天" }
                else if mins % 60 == 0 { label = "\(mins / 60) 小时" }
                else { label = "\(mins) 分钟" }
                let reset = (window["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                windows.append(UsageWindow(label: name.isEmpty ? label : "\(name) · \(label)",
                                           usedPercent: try percentage(window["usedPercent"]), resetAt: reset))
            }
        }
        guard !windows.isEmpty else { throw UsageFetchError.missingLimit }
        return ProviderUsageSummary(windows: windows)
    }
}

enum ClaudeUsageParser {
    static func parse(_ data: Data) throws -> ProviderUsageSummary {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageFetchError.parsing
        }
        let known = [("five_hour", "5 小时"), ("seven_day", "周"),
                     ("seven_day_sonnet", "Sonnet 周"), ("seven_day_opus", "Opus 周"),
                     ("seven_day_oauth_apps", "OAuth 周"), ("seven_day_cowork", "Cowork 周")]
        var windows: [UsageWindow] = []
        for (key, label) in known {
            guard let window = root[key] as? [String: Any] else { continue }
            let reset: Date?
            if let value = window["resets_at"] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                reset = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
                guard reset != nil else { throw UsageFetchError.parsing }
            } else { reset = nil }
            windows.append(UsageWindow(label: label, usedPercent: try percentage(window["utilization"]), resetAt: reset))
        }
        guard !windows.isEmpty else { throw UsageFetchError.missingLimit }
        return ProviderUsageSummary(windows: windows)
    }
}

enum LocalUsageError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let message): message } }
}

enum ClaudeLocalCredentials {
    static func accessToken(from data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw LocalUsageError.message("未找到 Claude 订阅登录，请在 Claude Code 中执行 /login")
        }
        // expiresAt describes an access token, not the renewable login session.
        // Let the usage endpoint validate it, and reread if the CLI rotated it.
        return token
    }
}
