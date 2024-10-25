//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
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

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
internal class AcceptHandler<ChildChannel: Channel>: ChannelInboundHandler {
    typealias InboundIn = ChildChannel
    typealias InboundOut = ChildChannel

    private let childChannelInitializer: ((Channel) -> EventLoopFuture<Void>)?
    private let childChannelOptions: ChannelOptions.Storage

    init(
        childChannelInitializer: ((Channel) -> EventLoopFuture<Void>)?,
        childChannelOptions: ChannelOptions.Storage
    ) {
        self.childChannelInitializer = childChannelInitializer
        self.childChannelOptions = childChannelOptions
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let newChannel = self.unwrapInboundIn(data)
        let childLoop = newChannel.eventLoop
        let ctxEventLoop = context.eventLoop
        let childInitializer = self.childChannelInitializer ?? { _ in childLoop.makeSucceededFuture(()) }

        @inline(__always)
        func setupChildChannel() -> EventLoopFuture<Void> {
            self.childChannelOptions.applyAllChannelOptions(to: newChannel).flatMap { () -> EventLoopFuture<Void> in
                childLoop.assertInEventLoop()
                return childInitializer(newChannel)
            }
        }

        @inline(__always)
        func fireThroughPipeline(_ future: EventLoopFuture<Void>) {
            ctxEventLoop.assertInEventLoop()
            future.flatMap { (_) -> EventLoopFuture<Void> in
                ctxEventLoop.assertInEventLoop()
                guard context.channel.isActive else {
                    return newChannel.close().flatMapThrowing {
                        throw ChannelError.ioOnClosedChannel
                    }
                }
                context.fireChannelRead(self.wrapInboundOut(newChannel))
                return context.eventLoop.makeSucceededFuture(())
            }.whenFailure { error in
                context.eventLoop.assertInEventLoop()
                _ = newChannel.close()
                context.fireErrorCaught(error)
            }
        }

        if childLoop === ctxEventLoop {
            fireThroughPipeline(setupChildChannel())
        } else {
            fireThroughPipeline(
                childLoop.flatSubmit {
                    setupChildChannel()
                }.hop(to: ctxEventLoop)
            )
        }
    }
}
#endif
