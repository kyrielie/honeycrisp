// swift-tools-version: 5.9
// Package.swift — alternative build entry point (SPM)
// Primary build target is the Xcode project: EPUBReader.xcodeproj

import PackageDescription

let package = Package(
    name: "Honeycrisp",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "Honeycrisp",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "Honeycrisp/Sources"
        ),
    ]
)
