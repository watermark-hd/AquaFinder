import XCTest
@testable import FSCore

final class FileListingTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileListingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testListsRegularFiles() throws {
        try "a".write(to: tempDir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try "a".write(to: tempDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let items = FileListing.contents(of: tempDir)
        XCTAssertEqual(items.map(\.name), ["a.txt", "b.txt"])
    }

    func testExcludesHiddenFiles() throws {
        try "a".write(to: tempDir.appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)
        try "a".write(to: tempDir.appendingPathComponent(".hidden.txt"), atomically: true, encoding: .utf8)

        let items = FileListing.contents(of: tempDir)
        XCTAssertEqual(items.map(\.name), ["visible.txt"])
    }

    func testIncludesSubdirectories() throws {
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("subfolder", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "a".write(to: tempDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let items = FileListing.contents(of: tempDir)
        XCTAssertEqual(items.count, 2)
        let folder = items.first { $0.name == "subfolder" }
        XCTAssertNotNil(folder)
        XCTAssertTrue(folder?.isDirectory ?? false)
    }

    func testNonexistentDirectoryReturnsEmpty() {
        let bogus = tempDir.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertEqual(FileListing.contents(of: bogus), [])
    }

    func testEmptyDirectoryReturnsEmpty() {
        XCTAssertEqual(FileListing.contents(of: tempDir), [])
    }
}
