import XCTest
@testable import FSCore

final class DirectoryListingCacheTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectoryListingCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        DirectoryListingCache.invalidateAll()
        DirectoryListingCache.onNewListing = nil
    }

    override func tearDownWithError() throws {
        DirectoryListingCache.invalidateAll()
        DirectoryListingCache.onNewListing = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeFile(_ name: String) throws {
        try "x".write(to: tempDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testContentsReflectsDiskOnFirstCall() throws {
        try writeFile("a.txt")
        let items = DirectoryListingCache.contents(of: tempDir)
        XCTAssertEqual(items.map(\.name), ["a.txt"])
    }

    func testContentsIsCachedUntilInvalidated() throws {
        try writeFile("a.txt")
        _ = DirectoryListingCache.contents(of: tempDir)

        // A file added after the first listing shouldn't appear until the
        // cache is explicitly invalidated — this is the whole point of the
        // cache existing (skip re-hitting disk on every call).
        try writeFile("b.txt")
        let stillCached = DirectoryListingCache.contents(of: tempDir)
        XCTAssertEqual(stillCached.map(\.name), ["a.txt"])

        DirectoryListingCache.invalidate(tempDir)
        let fresh = DirectoryListingCache.contents(of: tempDir)
        XCTAssertEqual(fresh.map(\.name), ["a.txt", "b.txt"])
    }

    func testInvalidateAllClearsEveryDirectory() throws {
        let otherDir = tempDir.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        try writeFile("a.txt")

        _ = DirectoryListingCache.contents(of: tempDir)
        _ = DirectoryListingCache.contents(of: otherDir)

        try "y".write(to: otherDir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        DirectoryListingCache.invalidateAll()

        XCTAssertEqual(DirectoryListingCache.contents(of: otherDir).map(\.name), ["b.txt"])
    }

    func testOnNewListingFiresForBothColdAndWarmReads() throws {
        try writeFile("a.txt")
        var callCount = 0
        DirectoryListingCache.onNewListing = { _ in callCount += 1 }

        _ = DirectoryListingCache.contents(of: tempDir)
        _ = DirectoryListingCache.contents(of: tempDir)

        XCTAssertEqual(callCount, 2, "onNewListing should fire on every call, cache hit or not")
    }

    func testAsyncVariantCallsCompletionWithDiskContents() throws {
        try writeFile("a.txt")
        let expectation = expectation(description: "completion fires")
        var received: [FileItem] = []

        DirectoryListingCache.contents(of: tempDir) { items in
            received = items
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(received.map(\.name), ["a.txt"])
    }

    func testAsyncVariantCacheHitCompletesSynchronously() throws {
        try writeFile("a.txt")
        _ = DirectoryListingCache.contents(of: tempDir) // warm the cache

        var completedSynchronously = false
        DirectoryListingCache.contents(of: tempDir) { _ in
            completedSynchronously = true
        }
        // No waiting on an expectation here on purpose — a cache hit is
        // documented to call back on the calling thread before returning.
        XCTAssertTrue(completedSynchronously)
    }

    /// Hammers the cache from many concurrent background threads at once —
    /// every production call site only ever touches this from the main
    /// thread, but the cache itself is meant to be safe regardless (see its
    /// own doc comment on the NSLock). This doesn't prove the original
    /// crash is fixed, but it is a real regression test: it would have
    /// been a reasonable way to catch the unguarded-dictionary version of
    /// this type before it ever shipped.
    func testConcurrentAccessDoesNotCrash() throws {
        try writeFile("a.txt")
        let expectation = expectation(description: "all threads finish")
        expectation.expectedFulfillmentCount = 8

        for _ in 0..<8 {
            DispatchQueue.global().async {
                for i in 0..<100 {
                    if i % 10 == 0 {
                        DirectoryListingCache.invalidate(self.tempDir)
                    }
                    _ = DirectoryListingCache.contents(of: self.tempDir)
                }
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 10)
    }
}
