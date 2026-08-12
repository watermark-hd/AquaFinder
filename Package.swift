// swift-tools-version:5.9
import PackageDescription

// Phase 4 adds FSQuickLook (real icon thumbnails via QuickLookThumbnailing;
// QLPreviewPanel itself is driven directly from FSWindow via `import
// Quartz` — no FSQuickLook types needed there, so no dependency edge).
// FSSearch was folded into FSWindow directly (NSMetadataQuery usage is
// small enough not to warrant its own module) rather than added as
// originally planned.
let package = Package(
    name: "AquaFinder",
    platforms: [.macOS(.v10_15)],
    targets: [
        .target(
            name: "FSCore",
            linkerSettings: [
                .linkedFramework("NetFS"),
            ]
        ),
        .target(name: "FSUIKit", dependencies: ["FSCore"]),
        .target(
            name: "FSQuickLook",
            dependencies: ["FSCore"],
            linkerSettings: [
                .linkedFramework("Quartz"),
                .linkedFramework("QuickLookThumbnailing"),
            ]
        ),
        .target(name: "FSSidebar", dependencies: ["FSCore", "FSUIKit"]),
        .target(name: "FSColumnView", dependencies: ["FSCore", "FSUIKit"]),
        .target(name: "FSListView", dependencies: ["FSCore", "FSUIKit"]),
        .target(name: "FSIconView", dependencies: ["FSCore", "FSUIKit", "FSQuickLook"]),
        .target(name: "FSGetInfo", dependencies: ["FSCore", "FSUIKit"]),
        .target(
            name: "FSWindow",
            dependencies: ["FSCore", "FSUIKit", "FSSidebar", "FSColumnView", "FSListView", "FSIconView", "FSGetInfo"]
        ),
        .executableTarget(name: "AquaFinderApp", dependencies: ["FSWindow"]),
    ]
)
