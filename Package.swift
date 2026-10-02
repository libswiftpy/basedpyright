// swift-tools-version: 6.2

import PackageDescription

// basedpyright's browser build, run by WebKit for Swift apps. The worker is
// built by Swift/build.sh and committed, so building needs no Node.
let package = Package(
    name: "basedpyright",
    platforms: [.macOS(.v14), .iOS(.v17), .visionOS(.v1)],
    products: [
        .library(name: "Pyright", targets: ["Pyright"]),
    ],
    targets: [
        .target(
            name: "Pyright",
            path: "Swift/Sources/Pyright",
            resources: [
                .copy("Resources/index.html"),
                .copy("Resources/pyright.worker.js"),
                .copy("Resources/LICENSE.txt"),
            ]
        ),
        .testTarget(
            name: "PyrightTests",
            dependencies: ["Pyright"],
            path: "Swift/Tests/PyrightTests"
        ),
    ]
)
