import Foundation
import XCTest
@testable import EiderKit

enum CatalogFixtures {
    static let sourceURL = URL(string: "https://example.com/repo/source.json")!

    static func data(_ name: String, file: StaticString = #filePath) throws -> Data {
        let directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        return try Data(contentsOf: directory.appendingPathComponent("Fixtures/\(name)"))
    }

    static func parse(_ name: String, from url: URL = sourceURL) throws -> CatalogSource {
        try SourceParser.parse(data: data(name), from: url)
    }

    static func temporaryHome() throws -> EiderPaths {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("eider-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return EiderPaths(environment: ["EIDER_HOME": directory.path])
    }
}

extension Date {
    static func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }
}
