// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WriteFlow",
    platforms: [.macOS(.v13)],
    targets: [
        // Languages, settings and the server client: no UI, so it can be unit tested.
        .target(name: "WriteFlowCore"),
        // The menu bar app.
        .executableTarget(name: "WriteFlow", dependencies: ["WriteFlowCore"]),
        .testTarget(name: "WriteFlowCoreTests", dependencies: ["WriteFlowCore"]),
    ]
)
