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
        // kimi-k2 行无 name/title → label 兜底「限额窗口」，且排在周窗口之前
        #expect(summary.windows.count == 2)
        #expect(summary.windows[0].label == "限额窗口")
        #expect(abs(summary.windows[0].usedPercent - 75.0) < 0.001)
        #expect(summary.windows[0].resetAt == nil)
        let weekly = try #require(summary.windows.last)
        #expect(weekly.label == "周")
        #expect(abs(weekly.usedPercent - 80.0) < 0.001)
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-08-30T00:00:00Z"))
        #expect(abs(weekly.resetAt!.timeIntervalSince(expected)) < 1)
    }

    // 多窗口：限额窗口在前（label 取行内 name 原文）、周窗口最后
    @Test func parseMultipleWindowsWithFiveHourFirst() throws {
        let json = """
        {"data":[
          {"model_name":"all","name":"Weekly Usage","used":800000,"limit":1000000,"resetTime":"2026-08-30T00:00:00Z"},
          {"model_name":"kimi-k2","name":"5 Hour Limit","used":300000,"limit":400000,"resetTime":1755900000}
        ]}
        """
        let summary = try KimiUsageParser.parse(Data(json.utf8))
        #expect(summary.windows.count == 2)
        #expect(summary.windows[0].label == "5 Hour Limit")
        #expect(abs(summary.windows[0].usedPercent - 75.0) < 0.001)
        #expect(summary.windows[1].label == "周")
        #expect(abs(summary.windows[1].usedPercent - 80.0) < 0.001)
    }

    // 字段名变体：used_amount / limit_amount + 秒级时间戳
    @Test func parseOldShapeFieldVariants() throws {
        let json = """
        {"usage":{"used_amount":40,"limit_amount":100,"reset_at":1755900000},
         "limits":[{"window":{"duration":300,"timeUnit":"MINUTES"},
                    "detail":{"used":10,"limit":100}}]}
        """
        let summary = try KimiUsageParser.parse(Data(json.utf8))
        // limits 的 300 MINUTES 可整除 60 → label「5 小时」，detail 数值同规则解析
        #expect(summary.windows.count == 2)
        #expect(summary.windows[0].label == "5 小时")
        #expect(abs(summary.windows[0].usedPercent - 10.0) < 0.001)
        #expect(summary.windows[0].resetAt == nil)
        let weekly = try #require(summary.windows.last)
        #expect(weekly.label == "周")
        #expect(abs(weekly.usedPercent - 40.0) < 0.001)
        #expect(abs(weekly.resetAt!.timeIntervalSince1970 - 1755900000) < 1)
    }

    // 只有 remaining 时：used = limit - remaining
    @Test func parseRemainingOnly() throws {
        let json = """
        {"data":[{"model_name":"all","limit":1000,"remaining":250}]}
        """
        let summary = try KimiUsageParser.parse(Data(json.utf8))
        #expect(summary.windows.count == 1)
        #expect(summary.windows[0].label == "周")
        #expect(abs(summary.windows[0].usedPercent - 75.0) < 0.001)
        #expect(summary.windows[0].resetAt == nil)
    }

    // 限额窗口 limit 缺失或 <= 0：跳过该窗口（不报错），周窗口仍正常解析
    @Test func skipsLimitWindowWithoutValidLimit() throws {
        let json = """
        {"data":[
          {"model_name":"all","used":800,"limit":1000,"resetTime":"2026-08-30T00:00:00Z"},
          {"model_name":"kimi-k2","used":100},
          {"model_name":"kimi-k2","used":100,"limit":0}
        ]}
        """
        let summary = try KimiUsageParser.parse(Data(json.utf8))
        #expect(summary.windows.count == 1)
        #expect(summary.windows[0].label == "周")
        #expect(abs(summary.windows[0].usedPercent - 80.0) < 0.001)
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

    // reset_in（距重置的相对秒数）回退：绝对字段缺失时生效
    @Test func parseResetInFallback() throws {
        let json = """
        {"data":[
          {"model_name":"all","used":80,"limit":100,"reset_in":17600}
        ]}
        """
        let summary = try KimiUsageParser.parse(Data(json.utf8))
        let resetAt = try #require(summary.windows.last?.resetAt)
        let delta = resetAt.timeIntervalSinceNow
        #expect(delta > 17595 && delta < 17605)   // ≈ now + 17600s，留 5s 容差
    }

    // 绝对字段优先于 reset_in
    @Test func absoluteResetTimeWinsOverResetIn() throws {
        let json = """
        {"data":[
          {"model_name":"all","used":80,"limit":100,"resetTime":1755900000,"reset_in":999999}
        ]}
        """
        let summary = try KimiUsageParser.parse(Data(json.utf8))
        #expect(abs((summary.windows.last?.resetAt ?? .distantPast).timeIntervalSince1970 - 1755900000) < 1)
    }

    // 真实接口格式：纳秒级小数的 ISO 时间戳（官方 kimi-cli 注释示例格式）
    @Test func parseNanosecondISOResetTime() throws {
        let json = """
        {"usage":{"used":80,"limit":100,"reset_at":"2026-08-25T05:24:18.443553353Z"},
         "limits":[]}
        """
        let summary = try KimiUsageParser.parse(Data(json.utf8))
        let resetAt = try #require(summary.windows.last?.resetAt)
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-08-25T05:24:18Z"))
        #expect(abs(resetAt.timeIntervalSince(expected)) < 1)
    }

    // 官方 resetAt 驼峰字段
    @Test func parseCamelCaseResetAt() throws {
        let json = """
        {"usage":{"used":80,"limit":100,"resetAt":"2026-08-25T05:24:18Z"}}
        """
        let summary = try KimiUsageParser.parse(Data(json.utf8))
        #expect(summary.windows.last?.resetAt != nil)
    }

    // ttl / resetIn 相对秒数字段
    @Test func parseTtlAndResetInVariants() throws {
        let ttl = """
        {"usage":{"used":80,"limit":100,"ttl":7200}}
        """
        #expect(try KimiUsageParser.parse(Data(ttl.utf8)).windows.last?.resetAt != nil)
        let resetIn = """
        {"usage":{"used":80,"limit":100,"resetIn":3600}}
        """
        #expect(try KimiUsageParser.parse(Data(resetIn.utf8)).windows.last?.resetAt != nil)
    }

    // 带时区偏移 + 微秒小数
    @Test func parseISOWithOffsetAndFraction() throws {
        let json = """
        {"usage":{"used":80,"limit":100,"reset_at":"2026-08-25T13:24:18.123456+08:00"}}
        """
        let summary = try KimiUsageParser.parse(Data(json.utf8))
        let resetAt = try #require(summary.windows.last?.resetAt)
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-08-25T05:24:18Z"))
        #expect(abs(resetAt.timeIntervalSince(expected)) < 1)
    }
}
