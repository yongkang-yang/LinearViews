// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LinearViews",
    platforms: [.macOS(.v14)],
    targets: [
        // Linear API client, view configuration, sorting. No UI, so it can be tested.
        .target(
            name: "LinearViewsKit",
            path: "Sources/LinearViewsKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Menu bar app: status item, issue panel, settings.
        .executableTarget(
            name: "LinearViews",
            dependencies: ["LinearViewsKit"],
            path: "Sources/LinearViews",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LinearViewsKitTests",
            dependencies: ["LinearViewsKit"],
            path: "Tests/LinearViewsKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
