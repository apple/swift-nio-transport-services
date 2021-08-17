// swift-tools-version:5.2
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
    products: [
        .library(name: "NIOTransportServices", targets: ["NIOTransportServices"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.32.0"),
    ],
    targets: [
        .target(
            name: "NIOTransportServices",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
            ]),
        .target(
            name: "NIOTSHTTPClient",
            dependencies: [
                "NIOTransportServices",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]),
        .target(
            name: "NIOTSHTTPServer",
            dependencies: [
                "NIOTransportServices",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]),
        .testTarget(
            name: "NIOTransportServicesTests",
            dependencies: [
                "NIOTransportServices",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ]),
    ]
)
