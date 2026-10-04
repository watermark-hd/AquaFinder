import XCTest
@testable import FSCore

final class FileOperationsTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileOperationsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    @discardableResult
    private func makeFile(_ name: String, in directory: URL? = nil, contents: String = "x") throws -> URL {
        let url = (directory ?? tempDir).appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - rename

    func testRenameSucceeds() throws {
        let original = try makeFile("a.txt")
        let renamed = try FileOperations.rename(original, to: "b.txt")
        XCTAssertEqual(renamed.lastPathComponent, "b.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
    }

    func testRenameToSameNameIsNoOp() throws {
        let original = try makeFile("a.txt")
        let result = try FileOperations.rename(original, to: "a.txt")
        XCTAssertEqual(result, original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testRenameRejectsEmptyName() throws {
        let original = try makeFile("a.txt")
        XCTAssertThrowsError(try FileOperations.rename(original, to: "   ")) { error in
            XCTAssertEqual(error as? FileOperationError, .invalidName)
        }
    }

    func testRenameRejectsSlashInName() throws {
        let original = try makeFile("a.txt")
        XCTAssertThrowsError(try FileOperations.rename(original, to: "a/b.txt")) { error in
            XCTAssertEqual(error as? FileOperationError, .invalidName)
        }
    }

    func testRenameRejectsDotAndDotDot() throws {
        let original = try makeFile("a.txt")
        XCTAssertThrowsError(try FileOperations.rename(original, to: ".")) { error in
            XCTAssertEqual(error as? FileOperationError, .invalidName)
        }
        XCTAssertThrowsError(try FileOperations.rename(original, to: "..")) { error in
            XCTAssertEqual(error as? FileOperationError, .invalidName)
        }
    }

    func testRenameRejectsExistingDestination() throws {
        let original = try makeFile("a.txt")
        try makeFile("b.txt")
        XCTAssertThrowsError(try FileOperations.rename(original, to: "b.txt")) { error in
            XCTAssertEqual(error as? FileOperationError, .destinationExists)
        }
    }

    // MARK: - duplicate

    func testDuplicateAppendsCopySuffix() throws {
        let original = try makeFile("photo.jpg")
        let duplicate = try FileOperations.duplicate(original)
        XCTAssertEqual(duplicate.lastPathComponent, "photo copy.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: duplicate.path))
    }

    func testDuplicateTwiceIncrementsCounter() throws {
        let original = try makeFile("photo.jpg")
        _ = try FileOperations.duplicate(original)
        let second = try FileOperations.duplicate(original)
        XCTAssertEqual(second.lastPathComponent, "photo copy 2.jpg")
    }

    func testDuplicatePreservesNoExtension() throws {
        let original = try makeFile("README")
        let duplicate = try FileOperations.duplicate(original)
        XCTAssertEqual(duplicate.lastPathComponent, "README copy")
    }

    // MARK: - move / copy (drag & drop)

    func testMoveAvoidsNameCollision() throws {
        let destinationDir = tempDir.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        try makeFile("a.txt", in: destinationDir)
        let source = try makeFile("a.txt", in: tempDir, contents: "source")

        let moved = try FileOperations.move(source, into: destinationDir)
        XCTAssertEqual(moved.lastPathComponent, "a 2.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testCopyAvoidsNameCollision() throws {
        let destinationDir = tempDir.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        try makeFile("a.txt", in: destinationDir)
        let source = try makeFile("a.txt", in: tempDir, contents: "source")

        let copied = try FileOperations.copy(source, into: destinationDir)
        XCTAssertEqual(copied.lastPathComponent, "a 2.txt")
        // The source must still exist — copy, unlike move, shouldn't remove it.
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testMoveIntoEmptyDestinationKeepsOriginalName() throws {
        let destinationDir = tempDir.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let source = try makeFile("a.txt")

        let moved = try FileOperations.move(source, into: destinationDir)
        XCTAssertEqual(moved.lastPathComponent, "a.txt")
    }

    // MARK: - resolveDragOperation

    func testDragOperationOptionForcesCopy() {
        let op = FileOperations.resolveDragOperation(
            source: tempDir, destinationDirectory: tempDir, optionHeld: true, commandHeld: true
        )
        XCTAssertEqual(op, .copy)
    }

    func testDragOperationCommandForcesMoveWhenOptionNotHeld() {
        let op = FileOperations.resolveDragOperation(
            source: tempDir, destinationDirectory: tempDir, optionHeld: false, commandHeld: true
        )
        XCTAssertEqual(op, .move)
    }

    func testDragOperationSameVolumeDefaultsToMove() throws {
        // resolveDragOperation reads the destination's real volumeURLKey —
        // a directory that doesn't exist on disk yet resolves to no volume
        // at all (nil), which would silently default to .copy regardless
        // of this test's intent, so the destination has to actually exist.
        let destinationDir = tempDir.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let op = FileOperations.resolveDragOperation(
            source: tempDir, destinationDirectory: destinationDir, optionHeld: false, commandHeld: false
        )
        XCTAssertEqual(op, .move)
    }

    // MARK: - createNewFolder

    func testCreateNewFolderAvoidsCollision() throws {
        let first = try FileOperations.createNewFolder(in: tempDir)
        let second = try FileOperations.createNewFolder(in: tempDir)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }
}
