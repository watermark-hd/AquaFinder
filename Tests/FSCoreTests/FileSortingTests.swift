import XCTest
@testable import FSCore

final class FileSortingTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileSortingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    @discardableResult
    private func makeFile(_ name: String, bytes: Int, modified: Date) throws -> FileItem {
        let url = tempDir.appendingPathComponent(name)
        try Data(repeating: 0, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return FileItem(url: url)
    }

    func testSortByNameIsLocalizedCaseInsensitive() throws {
        let now = Date()
        let b = try makeFile("banana.txt", bytes: 1, modified: now)
        let a = try makeFile("Apple.txt", bytes: 1, modified: now)
        let c = try makeFile("cherry.txt", bytes: 1, modified: now)

        let sorted = FileSorting.sorted([b, a, c], by: .name)
        XCTAssertEqual(sorted.map(\.name), ["Apple.txt", "banana.txt", "cherry.txt"])
    }

    func testSortByDateModifiedAscending() throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let oldest = try makeFile("oldest.txt", bytes: 1, modified: base)
        let middle = try makeFile("middle.txt", bytes: 1, modified: base.addingTimeInterval(100))
        let newest = try makeFile("newest.txt", bytes: 1, modified: base.addingTimeInterval(200))

        let sorted = FileSorting.sorted([newest, oldest, middle], by: .dateModified)
        XCTAssertEqual(sorted.map(\.name), ["oldest.txt", "middle.txt", "newest.txt"])
    }

    func testSortBySizeAscending() throws {
        let now = Date()
        let large = try makeFile("large.bin", bytes: 300, modified: now)
        let small = try makeFile("small.bin", bytes: 10, modified: now)
        let medium = try makeFile("medium.bin", bytes: 100, modified: now)

        let sorted = FileSorting.sorted([large, small, medium], by: .size)
        XCTAssertEqual(sorted.map(\.name), ["small.bin", "medium.bin", "large.bin"])
    }

    func testSortBySizeUsesFolderSizeCacheForDirectories() throws {
        let folderURL = tempDir.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let folder = FileItem(url: folderURL)
        let file = try makeFile("file.bin", bytes: 50, modified: Date())

        // Without a folder-size entry, the folder sorts as if it were 0
        // bytes — i.e. below any file with real content.
        let sortedWithoutCache = FileSorting.sorted([file, folder], by: .size)
        XCTAssertEqual(sortedWithoutCache.map(\.name), ["folder", "file.bin"])

        // With a folder-size entry larger than the file, it should sort after.
        let sortedWithCache = FileSorting.sorted([file, folder], by: .size, folderSizeCache: [folderURL: 1_000])
        XCTAssertEqual(sortedWithCache.map(\.name), ["file.bin", "folder"])
    }

    func testSortIsStableRegardingEqualKeys() throws {
        let now = Date()
        let items = try (0..<5).map { try makeFile("same-size-\($0).bin", bytes: 42, modified: now) }
        // All items have equal size — sorting by size shouldn't crash or
        // drop/duplicate any entries regardless of comparator tie-breaking.
        let sorted = FileSorting.sorted(items, by: .size)
        XCTAssertEqual(Set(sorted.map(\.name)), Set(items.map(\.name)))
        XCTAssertEqual(sorted.count, items.count)
    }
}
