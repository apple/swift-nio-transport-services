//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO


/// A `ChannelHandler` that checks for outbound writes of zero length, which are then dropped. This is
/// due to a bug in `Network Framework`, where zero byte TCP writes lead to stalled connections.
/// Write promises are confirmed in the correct order.
public final class NIOFilterEmptyWritesHandler: ChannelDuplexHandler {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    private enum ChannelState {
        case open
        case closedFromRemote
        case closedFromLocal
        case error
    }
    
    private var state: ChannelState = .closedFromLocal
    private var prefixEmptyWritePromise: Optional<EventLoopPromise<Void>>
    private var lastWritePromise: Optional<EventLoopPromise<Void>>
    
    public init() {
        self.prefixEmptyWritePromise = nil
        self.lastWritePromise = nil
    }
    
    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = self.unwrapOutboundIn(data)
        if buffer.readableBytes > 0 {
            if let promise = promise {
                self.lastWritePromise = promise
            } else {
                self.lastWritePromise = context.eventLoop.makePromise()
            }
            context.write(data, promise: self.lastWritePromise)
        } else {
            /*
             Empty writes needs to be handled individually depending on:
             A) Empty write occurring before any non-empty write needs a
             separate promise to cascade from (prefix)
             B) Non-empty writes carry a promise, that subsequent empty
             writes can cascade from
             */
            switch (self.prefixEmptyWritePromise, self.lastWritePromise, promise) {
            case (_, _, .none): break
            case (.none, .none, .some(let promise)):
                self.prefixEmptyWritePromise = promise
            case (_, .some(let lastWritePromise), .some(let promise)):
                lastWritePromise.futureResult.cascade(to: promise)
            case (.some(let prefixEmptyWritePromise), .none, .some(let promise)):
                prefixEmptyWritePromise.futureResult.cascade(to: promise)
            }
        }
    }
    
    public func flush(context: ChannelHandlerContext) {
        self.lastWritePromise = nil
        if let prefixEmptyWritePromise = self.prefixEmptyWritePromise {
            prefixEmptyWritePromise.futureResult.whenSuccess {
                context.flush()
            }
            prefixEmptyWritePromise.succeed(())
            self.prefixEmptyWritePromise = nil
        } else {
            context.flush()
        }
    }
}

// Connection state management
extension NIOFilterEmptyWritesHandler {
    public func channelActive(context: ChannelHandlerContext) {
        self.state = .open
        context.fireChannelActive()
    }
    
    public func channelInactive(context: ChannelHandlerContext) {
        if case .open = self.state {
            self.state = .closedFromRemote
            self.prefixEmptyWritePromise?.fail(ChannelError.eof)
        }
        self.prefixEmptyWritePromise = nil
        self.lastWritePromise = nil
        context.fireChannelInactive()
    }

    public func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        defer {
            context.close(mode: mode, promise: promise)
        }
        
        switch mode {
        case .all:
            if case .open = self.state {
                self.state = .closedFromLocal
                self.prefixEmptyWritePromise?.fail(ChannelError.ioOnClosedChannel)
            }
        case .output:
            if case .open = self.state {
                self.state = .closedFromLocal
                self.prefixEmptyWritePromise?.fail(ChannelError.outputClosed)
            }
        case .input:
            return
        }
        self.prefixEmptyWritePromise = nil
        self.lastWritePromise = nil
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        if case .open = self.state {
            self.state = .error
            self.prefixEmptyWritePromise?.fail(error)
        }
        self.prefixEmptyWritePromise = nil
        self.lastWritePromise = nil
        context.fireErrorCaught(error)
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive {
            self.state = .open
        }
    }
}
