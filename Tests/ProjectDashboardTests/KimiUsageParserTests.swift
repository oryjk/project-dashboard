import Foundation
import Testing
@testable import ProjectDashboard

struct KimiUsageParserTests {
    // 新端点 /usages 的结构：data 数组，model_name == "all" 为周用量汇总
    @Test func parseNewShapeSummaryRow() throws {
        let json = """
        {"code":0,"data":[
          {"model_name":"all","name":"Weekly Usage","used":800000,"limit":1000000,
           "resetTime":"2026-08-30T00:00:00Z"},
          {"model_name":"kimi-k2","used":300000,"limit":400000}
        ]}
        """
        let summary = try KimiUsageParser.parse(Data(json.utf8))
        #expect(abs(summary.usedPercent - 80.0) < 0.001)
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-08-30T00:00:00Z"))
        #expect(abs(summary.resetAt!.timeIntervalSince(expected)) < 1)
    }

    // 字段名变体：used_amount / limit_amount + 秒级时间戳
    @Test func parseOldShapeFieldVariants() throws {
        let json = """
        {"usage":{"used_amount":40,"limit_amount":100,"reset_at":1755900000},
         "limits":[{"window":{"duration":300,"timeUnit":"MINUTES"},
                    "detail":{"used":10,"limit":100}}]}
        """
        let summary = try KimiUsageParser.parse(Data(json.utf8))
        #expect(abs(summary.usedPercent - 40.0) < 0.001)
        #expect(abs(summary.resetAt!.timeIntervalSince1970 - 1755900000) < 1)
    }

    // 只有 remaining 时：used = limit - remaining
    @Test func parseRemainingOnly() throws {
        let json = """
        {"data":[{"model_name":"all","limit":1000,"remaining":250}]}
        """
        let summary = try KimiUsageParser.parse(Data(json.utf8))
        #expect(abs(summary.usedPercent - 75.0) < 0.001)
        #expect(summary.resetAt == nil)
    }

    // limit 缺失：明确报「接口未返回限额信息」而非通用解析错误
    @Test func missingLimitThrowsMissingLimit() {
        let json = """
        {"data":[{"model_name":"all","used":500}]}
        """
        #expect(throws: UsageFetchError.missingLimit) {
            try KimiUsageParser.parse(Data(json.utf8))
        }
    }

    // 没有汇总行（model_name != "all"）→ 解析失败
    @Test func missingSummaryRowThrowsParsing() {
        let json = """
        {"data":[{"model_name":"kimi-k2","used":1,"limit":2}]}
        """
        #expect(throws: UsageFetchError.parsing) {
            try KimiUsageParser.parse(Data(json.utf8))
        }
    }

    // 非 JSON 或结构完全不符 → 解析失败
    @Test func garbageThrowsParsing() {
        #expect(throws: UsageFetchError.parsing) {
            try KimiUsageParser.parse(Data("not json".utf8))
        }
    }
}
