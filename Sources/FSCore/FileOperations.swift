import Foundation

public enum FileOperationError: Error, LocalizedError {
    case invalidName
    case destinationExists

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            return "That name isn’t valid."
        case .destinationExists:
            return "An item with that name already exists."
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
        let base = "untitled folder"
        let first = directory.appendingPathComponent(base)
        if !fm.fileExists(atPath: first.path) { return first }
        var counter = 2
        while true {
            let candidate = directory.appendingPathComponent("\(base) \(counter)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    private static func duplicateURL(for url: URL, in directory: URL) -> URL {
        let fm = FileManager.default
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let firstName = ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)"
        let first = directory.appendingPathComponent(firstName)
        if !fm.fileExists(atPath: first.path) { return first }
        var counter = 2
        while true {
            let name = ext.isEmpty ? "\(base) copy \(counter)" : "\(base) copy \(counter).\(ext)"
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
