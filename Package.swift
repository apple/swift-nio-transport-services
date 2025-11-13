// swift-tools-version:6.0
//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2025 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import PackageDescription

let strictConcurrencyDevelopment = false

let strictConcurrencySettings: [SwiftSetting] = {
    var initialSettings: [SwiftSetting] = []

    if strictConcurrencyDevelopment {
        // -warnings-as-errors here is a workaround so that IDE-based development can
        // get tripped up on -require-explicit-sendable.
        initialSettings.append(.unsafeFlags(["-Xfrontend", "-require-explicit-sendable", "-warnings-as-errors"]))
    }

    return initialSettings
}()

let package = Package(
    name: "swift-nio-transport-services",
    products: [
        .library(name: "NIOTransportServices", targets: ["NIOTransportServices"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.83.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.0.2"),
    ],
    targets: [
        .target(
            name: "NIOTransportServices",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .executableTarget(
            name: "NIOTSHTTPClient",
            dependencies: [
                "NIOTransportServices",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "NIOTSHTTPServer",
            dependencies: [
                "NIOTransportServices",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "NIOTSEchoClient",
            dependencies: [
                "NIOTransportServices",
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "NIOTransportServicesTests",
            dependencies: [
                "NIOTransportServices",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            swiftSettings: strictConcurrencySettings
        ),
    ]
)

// ---    STANDARD CROSS-REPO SETTINGS DO NOT EDIT   --- //
for target in package.targets {
    switch target.type {
    case .regular, .test, .executable:
        var settings = target.swiftSettings ?? []
        // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0444-member-import-visibility.md
        settings.append(.enableUpcomingFeature("MemberImportVisibility"))
        target.swiftSettings = settings
    case .macro, .plugin, .system, .binary:
        ()  // not applicable
    @unknown default:
        ()  // we don't know what to do here, do nothing
    }
}
// --- END: STANDARD CROSS-REPO SETTINGS DO NOT EDIT --- //
