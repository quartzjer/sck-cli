// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "sck-cli",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "sck-cli", targets: ["sck-cli"]) 
    ],
    targets: [
        .executableTarget(
            name: "sck-cli",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Metal"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AppKit")
            ]
        )
    ]
)
