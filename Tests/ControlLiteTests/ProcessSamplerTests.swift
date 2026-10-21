import XCTest
import Darwin
@testable import ControlLite

final class ProcessSamplerTests: XCTestCase {
    /// 回归：proc_listallpids 返回的是进程个数而不是字节数。把它当字节数换算会让缓冲区只有真实进程数的
    /// 约四分之一，再被除以 4，结果只采样到 PID 最小的少数系统进程，主要进程榜单漏掉几乎所有用户应用。
    func testListPIDsCoversEveryRunningProcess() {
        var reference = [Int32](repeating: 0, count: 16_384)
        let total = Int(reference.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) })
        XCTAssertGreaterThan(total, 50, "测试环境应至少有数十个进程")
        let expected = Set(reference.prefix(total).filter { $0 > 0 })

        let listed = ProcessSampler.listPIDs()
        let covered = expected.intersection(listed).count
        // 采样期间进程会出现和退出，留出少量误差；旧实现只覆盖约 8%。
        XCTAssertGreaterThan(Double(covered) / Double(expected.count), 0.95,
                             "只列出了 \(covered)/\(expected.count) 个进程")
        XCTAssertTrue(listed.contains(getpid()), "必须包含当前进程")
        XCTAssertTrue(listed.contains(1), "必须包含 launchd")
        XCTAssertEqual(listed.max(), expected.max().map { max($0, listed.max() ?? 0) }, "PID 最大的进程不能被截断")
        XCTAssertFalse(listed.contains { $0 <= 0 })
        XCTAssertEqual(Set(listed).count, listed.count, "不应有重复 PID")
    }

    func testSampleReportsProcessesBeyondTheLowestPIDs() {
        let sampler = ProcessSampler()
        _ = sampler.sample(.memory)
        let result = sampler.sample(.memory)
        XCTAssertTrue(result.available)
        XCTAssertEqual(result.items.count, 5)
        // 当前测试进程至少占用数十 MB；榜单必须能反映内存占用最大的真实进程，而不是只看低 PID。
        XCTAssertFalse(result.items.allSatisfy { ($0.pid ?? 0) < 400 }, "榜单全部来自低 PID，说明进程列表被截断")
    }
}
