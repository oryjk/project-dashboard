import Foundation
import Testing
@testable import ProjectDashboard

struct GLMUsageParserTests {
    // 标准结构：data 包裹 limits，取 TOKENS_LIMIT（5 小时窗口）的 percentage
    @Test func parseStandardShape() throws {
        let json = """
        {"data":{"limits":[
          {"type":"TOKENS_LIMIT","percentage":55.5},
          {"type":"TIME_LIMIT","percentage":10,"currentValue":3,"usage":100}
        ]}}
        """
        let summary = try GLMUsageParser.parse(Data(json.utf8))
        #expect(abs(summary.usedPercent - 55.5) < 0.001)
        #expect(summary.resetAt == nil)
    }

    // 裸结构：limits 在根层级（与 glm-plan-usage 插件的 json.data || json 兼容逻辑一致）
    @Test func parseBareLimitsShape() throws {
        let json = """
        {"limits":[{"type":"TOKENS_LIMIT","percentage":30}]}
        """
        let summary = try GLMUsageParser.parse(Data(json.utf8))
        #expect(abs(summary.usedPercent - 30.0) < 0.001)
    }

    // 超出范围的百分比被钳制到 0...100
    @Test func clampsOutOfRangePercentage() throws {
        let json = """
        {"limits":[{"type":"TOKENS_LIMIT","percentage":130}]}
        """
        let summary = try GLMUsageParser.parse(Data(json.utf8))
        #expect(abs(summary.usedPercent - 100.0) < 0.001)
    }

    // 没有 TOKENS_LIMIT 类型 → 解析失败
    @Test func missingTokenLimitThrowsParsing() {
        let json = """
        {"limits":[{"type":"TIME_LIMIT","percentage":10}]}
        """
        #expect(throws: UsageFetchError.parsing) {
            try GLMUsageParser.parse(Data(json.utf8))
        }
    }

    // 非 JSON → 解析失败
    @Test func garbageThrowsParsing() {
        #expect(throws: UsageFetchError.parsing) {
            try GLMUsageParser.parse(Data("not json".utf8))
        }
    }
}
