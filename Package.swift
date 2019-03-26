// swift-tools-version:5.0
//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import PackageDescription

let package = Package(
    name: "swift-nio-transport-services",
    platforms: [
       .macOS(.v10_14), .iOS(.v12), .tvOS(.v12),
    ],
    products: [
        .library(name: "NIOTransportServices", targets: ["NIOTransportServices"]),
        .executable(name: "NIOTSHTTPClient", targets: ["NIOTSHTTPClient"]),
        .executable(name: "NIOTSHTTPServer", targets: ["NIOTSHTTPServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
    ],
    targets: [
        .target(name: "NIOTransportServices",
            dependencies: ["NIO", "NIOFoundationCompat", "NIOConcurrencyHelpers", "NIOTLS"]),
        .target(name: "NIOTSHTTPClient",
            dependencies: ["NIO", "NIOTransportServices", "NIOHTTP1"]),
        .target(name: "NIOTSHTTPServer",
            dependencies: ["NIO", "NIOTransportServices", "NIOHTTP1"]),
        .testTarget(name: "NIOTransportServicesTests",
            dependencies: ["NIO", "NIOTransportServices", "NIOConcurrencyHelpers"]),
    ]
)
