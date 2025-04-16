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

#if canImport(Network)
import NIOCore
import NIOTransportServices

func withEventLoopGroup(_ test: (EventLoopGroup) async throws -> Void) async rethrows {
    let group = NIOTSEventLoopGroup()
    do {
        try await test(group)
        try? await group.shutdownGracefully()
    } catch {
        try? await group.shutdownGracefully()
        throw error
    }
}

final class WaitForConnectionHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = Never

    let connectionPromise: EventLoopPromise<Void>

    init(connectionPromise: EventLoopPromise<Void>) {
        self.connectionPromise = connectionPromise
    }

    func channelActive(context: ChannelHandlerContext) {
        self.connectionPromise.succeed()
        context.fireChannelActive()
    }
}
#endif
