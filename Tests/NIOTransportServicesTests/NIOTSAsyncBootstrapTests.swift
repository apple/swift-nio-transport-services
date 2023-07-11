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
import NIOConcurrencyHelpers
@_spi(AsyncChannel) import NIOTransportServices
@_spi(AsyncChannel) import NIOCore
import XCTest
@_spi(AsyncChannel) import NIOTLS

private final class LineDelimiterCoder: ByteToMessageDecoder, MessageToByteEncoder {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let newLine = "\n".utf8.first!

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let readable = buffer.withUnsafeReadableBytes { $0.firstIndex(of: self.newLine) }
        if let readable = readable {
            context.fireChannelRead(self.wrapInboundOut(buffer.readSlice(length: readable)!))
            buffer.moveReaderIndex(forwardBy: 1)
            return .continue
        }
        return .needMoreData
    }

    func encode(data: ByteBuffer, out: inout ByteBuffer) throws {
        out.writeImmutableBuffer(data)
        out.writeString("\n")
    }
}

private final class TLSUserEventHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    enum ALPN: String {
        case string
        case byte
        case unknown
    }

    private var proposedALPN: ALPN?

    init(
        proposedALPN: ALPN? = nil
    ) {
        self.proposedALPN = proposedALPN
    }

    func handlerAdded(context: ChannelHandlerContext) {
        guard context.channel.isActive else {
            return
        }

        if let proposedALPN = self.proposedALPN {
            self.proposedALPN = nil
            context.writeAndFlush(.init(ByteBuffer(string: "negotiate-alpn:\(proposedALPN.rawValue)")), promise: nil)
        }
        context.fireChannelActive()
    }

    func channelActive(context: ChannelHandlerContext) {
        if let proposedALPN = self.proposedALPN {
            context.writeAndFlush(.init(ByteBuffer(string: "negotiate-alpn:\(proposedALPN.rawValue)")), promise: nil)
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)
        let string = String(buffer: buffer)

        if string.hasPrefix("negotiate-alpn:") {
            let alpn = String(string.dropFirst(15))
            context.writeAndFlush(.init(ByteBuffer(string: "alpn:\(alpn)")), promise: nil)
            context.fireUserInboundEventTriggered(TLSUserEvent.handshakeCompleted(negotiatedProtocol: alpn))
            context.pipeline.removeHandler(self, promise: nil)
        } else if string.hasPrefix("alpn:") {
            context.fireUserInboundEventTriggered(TLSUserEvent.handshakeCompleted(negotiatedProtocol: String(string.dropFirst(5))))
            context.pipeline.removeHandler(self, promise: nil)
        } else {
            context.fireChannelRead(data)
        }
    }
}

private final class ByteBufferToStringHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = String
    typealias OutboundIn = String
    typealias OutboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)
        context.fireChannelRead(self.wrapInboundOut(String(buffer: buffer)))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = ByteBuffer(string: self.unwrapOutboundIn(data))
        context.write(.init(buffer), promise: promise)
    }
}

private final class ByteBufferToByteHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = UInt8
    typealias OutboundIn = UInt8
    typealias OutboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = self.unwrapInboundIn(data)
        let byte = buffer.readInteger(as: UInt8.self)!
        context.fireChannelRead(self.wrapInboundOut(byte))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = ByteBuffer(integer: self.unwrapOutboundIn(data))
        context.write(.init(buffer), promise: promise)
    }
}

private final class AddressedEnvelopingHandler: ChannelDuplexHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = Any

    var remoteAddress: SocketAddress?

    init(remoteAddress: SocketAddress? = nil) {
        self.remoteAddress = remoteAddress
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = self.unwrapInboundIn(data)
        self.remoteAddress = envelope.remoteAddress

        context.fireChannelRead(self.wrapInboundOut(envelope.data))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = self.unwrapOutboundIn(data)
        if let remoteAddress = self.remoteAddress {
            context.write(self.wrapOutboundOut(AddressedEnvelope(remoteAddress: remoteAddress, data: buffer)), promise: promise)
            return
        }

        context.write(self.wrapOutboundOut(buffer), promise: promise)
    }
}

final class AsyncChannelBootstrapTests: XCTestCase {
    enum NegotiationResult {
        case string(NIOAsyncChannel<String, String>)
        case byte(NIOAsyncChannel<UInt8, UInt8>)
    }

    struct ProtocolNegotiationError: Error {}

    enum StringOrByte: Hashable {
        case string(String)
        case byte(UInt8)
    }

    func testServerClientBootstrap_withAsyncChannel_andHostPort() async throws {
        let eventLoopGroup = NIOTSEventLoopGroup(loopCount: 3)
        defer {
            try! eventLoopGroup.syncShutdownGracefully()
        }

        let channel = try await NIOTSListenerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: true)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineDelimiterCoder()))
                    try channel.pipeline.syncOperations.addHandler(MessageToByteHandler(LineDelimiterCoder()))
                    try channel.pipeline.syncOperations.addHandler(ByteBufferToStringHandler())
                }
            }
            .bind(
                host: "127.0.0.1",
                port: 0,
                childChannelConfiguration: .init(
                    inboundType: String.self,
                    outboundType: String.self
                )
            )

        try await withThrowingTaskGroup(of: Void.self) { group in
            let (stream, continuation) = AsyncStream<StringOrByte>.makeStream()
            var iterator = stream.makeAsyncIterator()

            group.addTask {
                try await withThrowingTaskGroup(of: Void.self) { _ in
                    for try await childChannel in channel.inboundStream {
                        for try await value in childChannel.inboundStream {
                            continuation.yield(.string(value))
                        }
                    }
                }
            }

            let stringChannel = try await self.makeClientChannel(eventLoopGroup: eventLoopGroup, port: channel.channel.localAddress!.port!)
            try await stringChannel.outboundWriter.write("hello")

            await XCTAsyncAssertEqual(await iterator.next(), .string("hello"))

            group.cancelAll()
        }
    }

    func testAsyncChannelProtocolNegotiation() async throws {
        let eventLoopGroup = NIOTSEventLoopGroup(loopCount: 3)
        defer {
            try! eventLoopGroup.syncShutdownGracefully()
        }

        let channel: NIOAsyncChannel<NegotiationResult, Never> = try await NIOTSListenerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: true)
            .bind(
                host: "127.0.0.1",
                port: 0
            ) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try self.configureProtocolNegotiationHandlers(channel: channel)
                }
            }

        try await withThrowingTaskGroup(of: Void.self) { group in
            let (stream, continuation) = AsyncStream<StringOrByte>.makeStream()
            var serverIterator = stream.makeAsyncIterator()

            group.addTask {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for try await childChannel in channel.inboundStream {
                        group.addTask {
                            switch childChannel {
                            case .string(let channel):
                                for try await value in channel.inboundStream {
                                    continuation.yield(.string(value))
                                }
                            case .byte(let channel):
                                for try await value in channel.inboundStream {
                                    continuation.yield(.byte(value))
                                }
                            }
                        }
                    }
                }
            }

            let stringNegotiationResult = try await self.makeClientChannelWithProtocolNegotiation(
                eventLoopGroup: eventLoopGroup,
                port: channel.channel.localAddress!.port!,
                proposedALPN: .string
            )
            switch stringNegotiationResult {
            case .string(let stringChannel):
                // This is the actual content
                try await stringChannel.outboundWriter.write("hello")
                await XCTAsyncAssertEqual(await serverIterator.next(), .string("hello"))
            case .byte:
                preconditionFailure()
            }

            let byteNegotiationResult = try await self.makeClientChannelWithProtocolNegotiation(
                eventLoopGroup: eventLoopGroup,
                port: channel.channel.localAddress!.port!,
                proposedALPN: .byte
            )
            switch byteNegotiationResult {
            case .string:
                preconditionFailure()
            case .byte(let byteChannel):
                // This is the actual content
                try await byteChannel.outboundWriter.write(UInt8(8))
                await XCTAsyncAssertEqual(await serverIterator.next(), .byte(8))
            }

            group.cancelAll()
        }
    }

    func testAsyncChannelNestedProtocolNegotiation() async throws {
        let eventLoopGroup = NIOTSEventLoopGroup(loopCount: 3)
        defer {
            try! eventLoopGroup.syncShutdownGracefully()
        }

        let channel: NIOAsyncChannel<NegotiationResult, Never> = try await NIOTSListenerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: true)
            .bind(
                host: "127.0.0.1",
                port: 0
            ) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try self.configureNestedProtocolNegotiationHandlers(channel: channel)
                }
            }

        try await withThrowingTaskGroup(of: Void.self) { group in
            let (stream, continuation) = AsyncStream<StringOrByte>.makeStream()
            var serverIterator = stream.makeAsyncIterator()

            group.addTask {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for try await childChannel in channel.inboundStream {
                        group.addTask {
                            switch childChannel {
                            case .string(let channel):
                                for try await value in channel.inboundStream {
                                    continuation.yield(.string(value))
                                }
                            case .byte(let channel):
                                for try await value in channel.inboundStream {
                                    continuation.yield(.byte(value))
                                }
                            }
                        }
                    }
                }
            }

            let stringStringNegotiationResult = try await self.makeClientChannelWithNestedProtocolNegotiation(
                eventLoopGroup: eventLoopGroup,
                port: channel.channel.localAddress!.port!,
                proposedOuterALPN: .string,
                proposedInnerALPN: .string
            )
            switch stringStringNegotiationResult {
            case .string(let stringChannel):
                // This is the actual content
                try await stringChannel.outboundWriter.write("hello")
                await XCTAsyncAssertEqual(await serverIterator.next(), .string("hello"))
            case .byte:
                preconditionFailure()
            }

            let byteStringNegotiationResult = try await self.makeClientChannelWithNestedProtocolNegotiation(
                eventLoopGroup: eventLoopGroup,
                port: channel.channel.localAddress!.port!,
                proposedOuterALPN: .byte,
                proposedInnerALPN: .string
            )
            switch byteStringNegotiationResult {
            case .string(let stringChannel):
                // This is the actual content
                try await stringChannel.outboundWriter.write("hello")
                await XCTAsyncAssertEqual(await serverIterator.next(), .string("hello"))
            case .byte:
                preconditionFailure()
            }

            let byteByteNegotiationResult = try await self.makeClientChannelWithNestedProtocolNegotiation(
                eventLoopGroup: eventLoopGroup,
                port: channel.channel.localAddress!.port!,
                proposedOuterALPN: .byte,
                proposedInnerALPN: .byte
            )
            switch byteByteNegotiationResult {
            case .string:
                preconditionFailure()
            case .byte(let byteChannel):
                // This is the actual content
                try await byteChannel.outboundWriter.write(UInt8(8))
                await XCTAsyncAssertEqual(await serverIterator.next(), .byte(8))
            }

            let stringByteNegotiationResult = try await self.makeClientChannelWithNestedProtocolNegotiation(
                eventLoopGroup: eventLoopGroup,
                port: channel.channel.localAddress!.port!,
                proposedOuterALPN: .string,
                proposedInnerALPN: .byte
            )
            switch stringByteNegotiationResult {
            case .string:
                preconditionFailure()
            case .byte(let byteChannel):
                // This is the actual content
                try await byteChannel.outboundWriter.write(UInt8(8))
                await XCTAsyncAssertEqual(await serverIterator.next(), .byte(8))
            }

            group.cancelAll()
        }
    }

    func testAsyncChannelProtocolNegotiation_whenFails() async throws {
        final class CollectingHandler: ChannelInboundHandler {
            typealias InboundIn = Channel

            private let channels: NIOLockedValueBox<[Channel]>

            init(channels: NIOLockedValueBox<[Channel]>) {
                self.channels = channels
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let channel = self.unwrapInboundIn(data)

                self.channels.withLockedValue { $0.append(channel) }

                context.fireChannelRead(data)
            }
        }
        let eventLoopGroup = NIOTSEventLoopGroup(loopCount: 3)
        defer {
            try! eventLoopGroup.syncShutdownGracefully()
        }
        let channels = NIOLockedValueBox<[Channel]>([Channel]())

        let channel: NIOAsyncChannel<NegotiationResult, Never> = try await NIOTSListenerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .serverChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(CollectingHandler(channels: channels))
                }
            }
            .childChannelOption(ChannelOptions.autoRead, value: true)
            .bind(
                host: "127.0.0.1",
                port: 0
            ) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try self.configureProtocolNegotiationHandlers(channel: channel)
                }
            }

        try await withThrowingTaskGroup(of: Void.self) { group in
            let (stream, continuation) = AsyncStream<StringOrByte>.makeStream()
            var serverIterator = stream.makeAsyncIterator()

            group.addTask {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for try await childChannel in channel.inboundStream {
                        group.addTask {
                            switch childChannel {
                            case .string(let channel):
                                for try await value in channel.inboundStream {
                                    continuation.yield(.string(value))
                                }
                            case .byte(let channel):
                                for try await value in channel.inboundStream {
                                    continuation.yield(.byte(value))
                                }
                            }
                        }
                    }
                }
            }

            await XCTAsyncAssertThrowsError(
                try await self.makeClientChannelWithProtocolNegotiation(
                    eventLoopGroup: eventLoopGroup,
                    port: channel.channel.localAddress!.port!,
                    proposedALPN: .unknown
                )
            ) { error in
                XCTAssertTrue(error is ProtocolNegotiationError)
            }

            // Let's check that we can still open a new connection
            let stringNegotiationResult = try await self.makeClientChannelWithProtocolNegotiation(
                eventLoopGroup: eventLoopGroup,
                port: channel.channel.localAddress!.port!,
                proposedALPN: .string
            )
            switch stringNegotiationResult {
            case .string(let stringChannel):
                // This is the actual content
                try await stringChannel.outboundWriter.write("hello")
                await XCTAsyncAssertEqual(await serverIterator.next(), .string("hello"))
            case .byte:
                preconditionFailure()
            }

            let failedInboundChannel = channels.withLockedValue { channels -> Channel in
                XCTAssertEqual(channels.count, 2)
                return channels[0]
            }

            // We are waiting here to make sure the channel got closed
            try await failedInboundChannel.closeFuture.get()

            group.cancelAll()
        }
    }

    // MARK: - Test Helpers

    private func makeClientChannel(eventLoopGroup: EventLoopGroup, port: Int) async throws -> NIOAsyncChannel<String, String> {
        return try await NIOTSConnectionBootstrap(group: eventLoopGroup)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(AddressedEnvelopingHandler())
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineDelimiterCoder()))
                    try channel.pipeline.syncOperations.addHandler(MessageToByteHandler(LineDelimiterCoder()))
                    try channel.pipeline.syncOperations.addHandler(ByteBufferToStringHandler())
                }
            }
            .connect(
                to: .init(ipAddress: "127.0.0.1", port: port),
                channelConfiguration: .init(
                    inboundType: String.self,
                    outboundType: String.self
                )
            )
    }

    private func makeClientChannelWithProtocolNegotiation(
        eventLoopGroup: EventLoopGroup,
        port: Int,
        proposedALPN: TLSUserEventHandler.ALPN
    ) async throws -> NegotiationResult {
        return try await NIOTSConnectionBootstrap(group: eventLoopGroup)
            .connect(
                to: .init(ipAddress: "127.0.0.1", port: port)
            ) { channel in
                return channel.eventLoop.makeCompletedFuture {
                    return try self.configureProtocolNegotiationHandlers(channel: channel, proposedALPN: proposedALPN)
                }
            }
    }

    private func makeClientChannelWithNestedProtocolNegotiation(
        eventLoopGroup: EventLoopGroup,
        port: Int,
        proposedOuterALPN: TLSUserEventHandler.ALPN,
        proposedInnerALPN: TLSUserEventHandler.ALPN
    ) async throws -> NegotiationResult {
        return try await NIOTSConnectionBootstrap(group: eventLoopGroup)
            .connect(
                to: .init(ipAddress: "127.0.0.1", port: port)
            ) { channel in
                return channel.eventLoop.makeCompletedFuture {
                    try self.configureNestedProtocolNegotiationHandlers(
                        channel: channel,
                        proposedOuterALPN: proposedOuterALPN,
                        proposedInnerALPN: proposedInnerALPN
                    )
                }
            }
    }

    @discardableResult
    private func configureProtocolNegotiationHandlers(
        channel: Channel,
        proposedALPN: TLSUserEventHandler.ALPN? = nil
    ) throws -> NIOTypedApplicationProtocolNegotiationHandler<NegotiationResult> {
        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineDelimiterCoder()))
        try channel.pipeline.syncOperations.addHandler(MessageToByteHandler(LineDelimiterCoder()))
        try channel.pipeline.syncOperations.addHandler(TLSUserEventHandler(proposedALPN: proposedALPN))
        return try self.addTypedApplicationProtocolNegotiationHandler(to: channel)
    }

    @discardableResult
    private func configureNestedProtocolNegotiationHandlers(
        channel: Channel,
        proposedOuterALPN: TLSUserEventHandler.ALPN? = nil,
        proposedInnerALPN: TLSUserEventHandler.ALPN? = nil
    ) throws -> NIOTypedApplicationProtocolNegotiationHandler<NegotiationResult> {
        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineDelimiterCoder()))
        try channel.pipeline.syncOperations.addHandler(MessageToByteHandler(LineDelimiterCoder()))
        try channel.pipeline.syncOperations.addHandler(TLSUserEventHandler(proposedALPN: proposedOuterALPN))
        let negotiationHandler = NIOTypedApplicationProtocolNegotiationHandler<NegotiationResult>(eventLoop: channel.eventLoop) { alpnResult, channel in
            switch alpnResult {
            case .negotiated(let alpn):
                switch alpn {
                case "string":
                    return channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(TLSUserEventHandler(proposedALPN: proposedInnerALPN))
                        let negotiationFuture = try self.addTypedApplicationProtocolNegotiationHandler(to: channel)

                        return NIOProtocolNegotiationResult.deferredResult(negotiationFuture.protocolNegotiationResult)
                    }
                case "byte":
                    return channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(TLSUserEventHandler(proposedALPN: proposedInnerALPN))
                        let negotiationHandler = try self.addTypedApplicationProtocolNegotiationHandler(to: channel)

                        return NIOProtocolNegotiationResult.deferredResult(negotiationHandler.protocolNegotiationResult)
                    }
                default:
                    return channel.eventLoop.makeFailedFuture(ProtocolNegotiationError())
                }
            case .fallback:
                return channel.eventLoop.makeFailedFuture(ProtocolNegotiationError())
            }
        }
        try channel.pipeline.syncOperations.addHandler(negotiationHandler)
        return negotiationHandler
    }

    @discardableResult
    private func addTypedApplicationProtocolNegotiationHandler(to channel: Channel) throws -> NIOTypedApplicationProtocolNegotiationHandler<NegotiationResult> {
        let negotiationHandler = NIOTypedApplicationProtocolNegotiationHandler<NegotiationResult>(eventLoop: channel.eventLoop) { alpnResult, channel in
            switch alpnResult {
            case .negotiated(let alpn):
                switch alpn {
                case "string":
                    return channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(ByteBufferToStringHandler())
                        let asyncChannel: NIOAsyncChannel<String, String> = try NIOAsyncChannel(
                            synchronouslyWrapping: channel
                        )

                        return NIOProtocolNegotiationResult.finished(NegotiationResult.string(asyncChannel))
                    }
                case "byte":
                    return channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(ByteBufferToByteHandler())

                        let asyncChannel: NIOAsyncChannel<UInt8, UInt8> = try NIOAsyncChannel(
                            synchronouslyWrapping: channel
                        )

                        return NIOProtocolNegotiationResult.finished(NegotiationResult.byte(asyncChannel))
                    }
                default:
                    return channel.eventLoop.makeFailedFuture(ProtocolNegotiationError())
                }
            case .fallback:
                return channel.eventLoop.makeFailedFuture(ProtocolNegotiationError())
            }
        }

        try channel.pipeline.syncOperations.addHandler(negotiationHandler)
        return negotiationHandler
    }
}

extension AsyncStream {
    fileprivate static func makeStream(
        of elementType: Element.Type = Element.self,
        bufferingPolicy limit: Continuation.BufferingPolicy = .unbounded
    ) -> (stream: AsyncStream<Element>, continuation: AsyncStream<Element>.Continuation) {
        var continuation: AsyncStream<Element>.Continuation!
        let stream = AsyncStream<Element>(bufferingPolicy: limit) { continuation = $0 }
        return (stream: stream, continuation: continuation!)
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
private func XCTAsyncAssertEqual<Element: Equatable>(_ lhs: @autoclosure () async throws -> Element, _ rhs: @autoclosure () async throws -> Element, file: StaticString = #filePath, line: UInt = #line) async rethrows {
    let lhsResult = try await lhs()
    let rhsResult = try await rhs()
    XCTAssertEqual(lhsResult, rhsResult, file: file, line: line)
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
private func XCTAsyncAssertThrowsError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (_ error: Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message(), file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
internal func XCTAsyncAssertThrowsError<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    verify: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expression did not throw error", file: file, line: line)
    } catch {
        verify(error)
    }
}
#endif
