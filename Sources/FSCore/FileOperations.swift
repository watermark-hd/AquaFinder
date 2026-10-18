import Foundation

public enum FileOperationError: Error, LocalizedError, Equatable {
    case invalidName
    case destinationExists
    case compressFailed

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            return NSLocalizedString("That name isn’t valid.", comment: "リネーム/新規作成時に無効な名前が指定されたときのエラー")
        case .destinationExists:
            return NSLocalizedString("An item with that name already exists.", comment: "同名の項目が既に存在するときのエラー")
        case .compressFailed:
            return NSLocalizedString("Couldn’t create the archive.", comment: "圧縮に失敗したときのエラー")
        }
    }
}

public enum DragOperationKind {
    case copy
    case move
}

public enum FileOperations {
    // MARK: - Creation / rename / duplicate

    @discardableResult
    public static func createNewFolder(in directory: URL) throws -> URL {
        let url = newFolderURL(in: directory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @discardableResult
    public static func rename(_ url: URL, to newName: String) throws -> URL {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), trimmed != ".", trimmed != ".." else {
            throw FileOperationError.invalidName
        }
        let destination = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        guard destination.path != url.path else { return url }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw FileOperationError.destinationExists
        }
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    @discardableResult
    public static func duplicate(_ url: URL) throws -> URL {
        let directory = url.deletingLastPathComponent()
        let destination = duplicateURL(for: url, in: directory)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    /// Zips a single item into `<name>.zip` alongside it — matches real
    /// Finder's "Compress" right-click item (currently the only case the
    /// context menu ever builds: it's already single-item-only for
    /// Duplicate/Move to Trash too, even under a multi-selection).
    /// `ditto` is what Finder's own Compress uses internally; shelling out
    /// to it avoids reimplementing zip's format and its resource-fork/
    /// extended-attribute preservation rules.
    @discardableResult
    public static func compress(_ url: URL) throws -> URL {
        let directory = url.deletingLastPathComponent()
        let destination = uniqueURL(for: directory.appendingPathComponent("\(url.lastPathComponent).zip"), in: directory)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // --keepParent embeds url's own name as the archive's top-level
        // entry, so extracting the zip gives back the original item
        // (a file or a folder), not just its loose contents.
        process.arguments = ["-c", "-k", "--keepParent", url.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FileOperationError.compressFailed
        }
        return destination
    }

    // MARK: - Trash

    @discardableResult
    public static func moveToTrash(_ url: URL) throws -> URL {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return (resultingURL as URL?) ?? url
    }

    public static func emptyTrash() throws {
        let trashURL = try FileManager.default.url(
            for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )
        let contents = try FileManager.default.contentsOfDirectory(
            at: trashURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        for item in contents {
            try FileManager.default.removeItem(at: item)
        }
    }

    // MARK: - Copy / move (drag & drop)

    @discardableResult
    public static func copy(_ url: URL, into destinationDirectory: URL) throws -> URL {
        let proposed = destinationDirectory.appendingPathComponent(url.lastPathComponent)
        let destination = uniqueURL(for: proposed, in: destinationDirectory)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    @discardableResult
    public static func move(_ url: URL, into destinationDirectory: URL) throws -> URL {
        let proposed = destinationDirectory.appendingPathComponent(url.lastPathComponent)
        let destination = uniqueURL(for: proposed, in: destinationDirectory)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    /// Same as `copy(_:into:)`, but runs off the main thread and reports
    /// real byte-level progress — large files (RAW photos, video) used to
    /// copy synchronously on whatever thread called this, which in
    /// practice was always the main thread (drag & drop, paste), freezing
    /// the whole app with no feedback for as long as the copy took.
    ///
    /// Regular files are copied by hand in chunks, updating `Progress`
    /// after every chunk — `FileManager.copyItem`'s own "current Progress"
    /// publishing (the documented, no-manual-tracking-needed mechanism)
    /// turned out not to report any intermediate progress for a single
    /// large file in practice: the bar just sat empty for the whole
    /// transfer and then the operation completed, which is worse than
    /// having no bar at all for exactly the case (one big file) this
    /// exists for. Directories still go through `FileManager.copyItem`
    /// (correctly handles nested structure, resource forks, etc.) and so
    /// still only report coarse 0%-then-done progress — a real gap, but a
    /// much rarer/lower-stakes one than the single-huge-file case.
    @discardableResult
    public static func copyAsync(
        _ url: URL, into destinationDirectory: URL, completion: @escaping (Result<URL, Error>) -> Void
    ) -> Progress {
        let proposed = destinationDirectory.appendingPathComponent(url.lastPathComponent)
        let destination = uniqueURL(for: proposed, in: destinationDirectory)
        let progress = Progress(totalUnitCount: 1)
        progress.isCancellable = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<URL, Error>
            do {
                if isRegularFile(url) {
                    try copyFileWithProgress(from: url, to: destination, progress: progress)
                } else {
                    try FileManager.default.copyItem(at: url, to: destination)
                }
                result = .success(destination)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
        return progress
    }

    @discardableResult
    public static func moveAsync(
        _ url: URL, into destinationDirectory: URL, completion: @escaping (Result<URL, Error>) -> Void
    ) -> Progress {
        let proposed = destinationDirectory.appendingPathComponent(url.lastPathComponent)
        let destination = uniqueURL(for: proposed, in: destinationDirectory)
        let progress = Progress(totalUnitCount: 1)
        progress.isCancellable = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<URL, Error>
            do {
                // A same-volume move is a near-instant rename — only a
                // cross-volume move is actually a copy-then-delete under
                // the hood, and only that case benefits from (or needs)
                // chunked progress reporting.
                let sameVolume = (try? url.resourceValues(forKeys: [.volumeURLKey]).volume)
                    == (try? destinationDirectory.resourceValues(forKeys: [.volumeURLKey]).volume)
                if sameVolume {
                    try FileManager.default.moveItem(at: url, to: destination)
                } else if isRegularFile(url) {
                    try copyFileWithProgress(from: url, to: destination, progress: progress)
                    try FileManager.default.removeItem(at: url)
                } else {
                    try FileManager.default.copyItem(at: url, to: destination)
                    try FileManager.default.removeItem(at: url)
                }
                result = .success(destination)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
        return progress
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
    }

    /// Reads/writes in fixed-size chunks so `progress.completedUnitCount`
    /// reflects real bytes transferred, instead of jumping straight from
    /// 0% to 100% the way a single whole-file `FileManager.copyItem` call
    /// does from the caller's perspective. Checked for cancellation
    /// between chunks — coarser than mid-chunk, but a 4MB chunk is a few
    /// milliseconds even on a slow link, which is plenty responsive for a
    /// Stop button.
    private static func copyFileWithProgress(from source: URL, to destination: URL, progress: Progress) throws {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? nil
        progress.totalUnitCount = max(fileSize ?? 1, 1)

        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw FileOperationError.destinationExists
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        let chunkSize = 4 * 1024 * 1024
        while true {
            if progress.isCancelled {
                throw CocoaError(.userCancelled)
            }
            let chunk = input.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            output.write(chunk)
            progress.completedUnitCount += Int64(chunk.count)
        }
    }

    /// Classic Finder drag semantics: same-volume drag defaults to a move,
    /// cross-volume defaults to a copy; ⌥ always forces copy, ⌘ always
    /// forces move.
    public static func resolveDragOperation(
        source: URL,
        destinationDirectory: URL,
        optionHeld: Bool,
        commandHeld: Bool
    ) -> DragOperationKind {
        if optionHeld { return .copy }
        if commandHeld { return .move }
        let sourceVolume = try? source.resourceValues(forKeys: [.volumeURLKey]).volume
        let destinationVolume = try? destinationDirectory.resourceValues(forKeys: [.volumeURLKey]).volume
        return (sourceVolume ?? nil) == (destinationVolume ?? nil) ? .move : .copy
    }

    // MARK: - Naming helpers

    private static func newFolderURL(in directory: URL) -> URL {
        let fm = FileManager.default
        let base = NSLocalizedString("untitled folder", comment: "新規フォルダのデフォルト名")
        let first = directory.appendingPathComponent(base)
        if !fm.fileExists(atPath: first.path) { return first }
        var counter = 2
        while true {
            let format = NSLocalizedString("%@ %d", comment: "同名衝突時に連番を付与した新規フォルダ名（%@=ベース名, %d=連番）")
            let candidate = directory.appendingPathComponent(String(format: format, base, counter))
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    private static func duplicateURL(for url: URL, in directory: URL) -> URL {
        let fm = FileManager.default
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let firstNameFormat = NSLocalizedString("%@ copy", comment: "複製ファイルのデフォルト名（%@=元のファイル名）")
        let firstBaseName = String(format: firstNameFormat, base)
        let firstName = ext.isEmpty ? firstBaseName : "\(firstBaseName).\(ext)"
        let first = directory.appendingPathComponent(firstName)
        if !fm.fileExists(atPath: first.path) { return first }
        var counter = 2
        while true {
            let nameFormat = NSLocalizedString("%@ copy %d", comment: "複製ファイルの連番付きデフォルト名（%@=元のファイル名, %d=連番）")
            let baseNameWithCounter = String(format: nameFormat, base, counter)
            let name = ext.isEmpty ? baseNameWithCounter : "\(baseNameWithCounter).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    private static func uniqueURL(for proposedURL: URL, in directory: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: proposedURL.path) else { return proposedURL }
        let ext = proposedURL.pathExtension
        let base = proposedURL.deletingPathExtension().lastPathComponent
        var counter = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }
}
