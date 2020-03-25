//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
// swift-tools-version:4.0
//
// swift-tools-version:4.0
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO


/// A `ChannelHandler` that checks for outbound writes of zero length, which are then dropped. This is
/// due to a bug in `Network Framework`, where zero byte TCP writes lead to stalled connections.
/// Write promises are confirmed in the correct order.
public final class FilterEmptyWritesHandler: ChannelOutboundHandler {
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    private var prefixEmptyWritePromise: Optional<EventLoopPromise<Void>>
    private var lastWritePromise: Optional<EventLoopPromise<Void>>
    
    public init() {
        self.prefixEmptyWritePromise = nil
        self.lastWritePromise = nil
    }
    
    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = self.unwrapOutboundIn(data)
        if buffer.readableBytes > 0, let promise = promise {
            self.lastWritePromise = promise
        }
        guard buffer.readableBytes == 0 else {
            context.write(data, promise: promise)
            return
        }
        
        switch (self.prefixEmptyWritePromise, self.lastWritePromise, promise) {
        case (_, _, .none): break
        case (.none, .none, .some(let promise)): // first empty write with promise
            self.prefixEmptyWritePromise = promise
        case (_, .some(let lastWritePromise), .some(let promise)):
            lastWritePromise.futureResult.cascade(to: promise)
        case (.some(let prefixEmptyWritePromise), .none, .some(let promise)):
            prefixEmptyWritePromise.futureResult.cascade(to: promise)
        }
    }
    
    public func flush(context: ChannelHandlerContext) {
        self.prefixEmptyWritePromise?.succeed(())
        self.prefixEmptyWritePromise = nil
        self.lastWritePromise = nil

        context.flush()
    }
}

extension FilterEmptyWritesHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer

    public func channelInactive(context: ChannelHandlerContext) {
        self.prefixEmptyWritePromise?.fail(ChannelError.ioOnClosedChannel)
        self.prefixEmptyWritePromise = nil
        self.lastWritePromise = nil
        
        context.fireChannelInactive()
    }
}
