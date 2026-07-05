// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SDReview",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SDReview", targets: ["SDReview"]),
        .library(name: "SDReviewCore", targets: ["SDReviewCore"])
    ],
    targets: [
        .target(
            name: "SDReviewCore",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("ImageIO"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .executableTarget(
            name: "SDReview",
            dependencies: ["SDReviewCore"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "SDReviewCoreTests",
            dependencies: ["SDReviewCore"]
        )
    ]
)
