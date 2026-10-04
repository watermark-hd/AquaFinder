import AppKit
import FSCore
import FSUIKit
import FSQuickLook
import Foundation

// Not part of the shipped app — a throwaway driver to exercise
// DirectoryListingCache / IconCache / ThumbnailLoader against a real SMB
// mount (same class of hardware the "NAS slowness" report was about),
// both to measure real timings and to stress-test the new NSLock-guarded
// caches under genuinely concurrent access, not just the main-thread-only
// access every production call site happens to use today.

// Unbuffered stdout — otherwise nothing shows up in a redirected/piped
// output until the whole process exits, which made an earlier run of this
// probe look hung when it was actually just slow (and, separately, a real
// deadlock elsewhere looked identical for the same reason).
setvbuf(stdout, nil, _IONBF, 0)

guard CommandLine.arguments.count > 1 else {
    print("usage: StabilityProbe <directory>")
    exit(1)
}
let targetURL = URL(fileURLWithPath: CommandLine.arguments[1])

func time(_ label: String, _ body: () -> Void) {
    let start = Date()
    body()
    let elapsed = Date().timeIntervalSince(start)
    print(String(format: "%-55@ %.3fs", label as NSString, elapsed))
}

/// Blocks the calling thread until `isDone()` returns true, WITHOUT
/// starving the main run loop the way `DispatchGroup.wait()` would —
/// `ThumbnailLoader`'s completion is delivered via `DispatchQueue.main.async`,
/// and blocking the main thread synchronously (the first version of this
/// probe did exactly that) means that block can never actually run, which
/// means the wait never ends. This drives the run loop in short bursts
/// instead, which is what actually lets main-queue work execute while
/// "waiting".
func pumpRunLoop(until isDone: () -> Bool, timeout: TimeInterval) {
    let deadline = Date().addingTimeInterval(timeout)
    while !isDone(), Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

print("=== Target: \(targetURL.path) ===")

var items: [FileItem] = []
time("FileListing.contents(of:) cold") {
    items = FileListing.contents(of: targetURL)
}
print("  \(items.count) items")

time("DirectoryListingCache.contents(of:) cold (invalidated first)") {
    DirectoryListingCache.invalidate(targetURL)
    _ = DirectoryListingCache.contents(of: targetURL)
}
time("DirectoryListingCache.contents(of:) warm (cache hit)") {
    _ = DirectoryListingCache.contents(of: targetURL)
}

time("IconCache.icon(for:) sync, cold, \(items.count) items") {
    for item in items {
        _ = IconCache.icon(for: item.url)
    }
}
time("IconCache.icon(for:) sync, warm, \(items.count) items") {
    for item in items {
        _ = IconCache.icon(for: item.url)
    }
}

var thumbSuccessCount = 0
time("ThumbnailLoader.thumbnail(for:) async, cold, \(items.count) items") {
    for item in items {
        ThumbnailLoader.thumbnail(for: item.url, size: CGSize(width: 64, height: 64), scale: 2) { _ in
            thumbSuccessCount += 1
        }
    }
    pumpRunLoop(until: { thumbSuccessCount >= items.count }, timeout: 120)
}
print("  \(thumbSuccessCount)/\(items.count) thumbnails resolved")

// --- Concurrency stress test ---
// Every production call site only ever touches DirectoryListingCache /
// ThumbnailLoader from the main thread, but the whole point of hardening
// them with NSLock was to make them safe even if that stops being true.
// Hammer both from many concurrent background threads at once, repeatedly
// invalidating and re-reading the same real network-backed directory, and
// confirm nothing crashes or deadlocks.
print("\n=== Concurrency stress (8 threads x 50 iterations against a real SMB mount) ===")
var stressDone = false
let stressQueue = DispatchQueue(label: "stress", attributes: .concurrent)
let stressGroup = DispatchGroup()
var stressErrors = 0
let stressLock = NSLock()
let stressStart = Date()
for t in 0..<8 {
    stressGroup.enter()
    stressQueue.async {
        for i in 0..<50 {
            if i % 10 == 0 {
                DirectoryListingCache.invalidate(targetURL)
            }
            let listed = DirectoryListingCache.contents(of: targetURL)
            if listed.isEmpty {
                stressLock.lock()
                stressErrors += 1
                stressLock.unlock()
            }
            if let first = listed.first {
                _ = IconCache.icon(for: first.url)
                ThumbnailLoader.thumbnail(for: first.url, size: CGSize(width: 32, height: 32), scale: 2) { _ in }
            }
        }
        stressGroup.leave()
    }
}
stressGroup.notify(queue: .main) { stressDone = true }
pumpRunLoop(until: { stressDone }, timeout: 180)
let stressElapsed = Date().timeIntervalSince(stressStart)
print(String(format: "stress test %@ in %.3fs, %d unexpected empty listings",
             stressDone ? "completed" : "TIMED OUT", stressElapsed, stressErrors))

print("\n=== Done, no crash ===")
