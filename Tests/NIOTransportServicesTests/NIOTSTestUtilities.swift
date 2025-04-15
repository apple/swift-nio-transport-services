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

import NIOCore
import NIOTransportServices

func withEventLoopGroup(_ test: (EventLoopGroup) async throws -> Void) async rethrows {
    let group = NIOTSEventLoopGroup()
    do {
        try await test(group)
    } catch {
        try await group.shutdownGracefully()
        throw error
    }
}
