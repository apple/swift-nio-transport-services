//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if canImport(Network)
import XCTest
import Network
import NIOCore
import NIOFoundationCompat
import NIOTransportServices
import Foundation
import NIOConcurrencyHelpers

@available(macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 6, *)
final class ConnectRecordingHandler: ChannelOutboundHandler {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    var connectTargets: [SocketAddress] = []
    var endpointTargets: [NWEndpoint] = []

    func connect(context: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        self.connectTargets.append(address)
        context.connect(to: address, promise: promise)
    }

    func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        switch event {
        case let evt as NIOTSNetworkEvents.ConnectToNWEndpoint:
            self.endpointTargets.append(evt.endpoint)
        default:
            break
        }
        context.triggerUserOutboundEvent(event, promise: promise)
    }
}

final class FailOnReadHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        XCTFail("Must not read")
        context.fireChannelRead(data)
    }
}

final class WritabilityChangedHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let cb: (Bool) -> Void

    init(_ cb: @escaping (Bool) -> Void) {
        self.cb = cb
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        self.cb(context.channel.isWritable)
    }
}

@available(macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 6, *)
final class DisableWaitingAfterConnect: ChannelOutboundHandler {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    func connect(context: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        do {
            try context.channel.syncOptions?.setOption(NIOTSChannelOptions.waitForActivity, value: false)
        } catch {
            promise?.fail(error)
            return
        }

        context.connect(to: address).cascade(to: promise)
    }
}

@available(macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 6, *)
final class EnableWaitingAfterWaiting: ChannelInboundHandler {
    typealias InboundIn = Any
    typealias InboundOut = Any

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is NIOTSNetworkEvents.WaitingForConnectivity {
            // Note that this is the default value and is set to _true_.
            try! context.channel.syncOptions!.setOption(NIOTSChannelOptions.waitForActivity, value: true)
        }
    }
}

final class PromiseOnActiveHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    typealias InboundOut = Any

    private let promise: EventLoopPromise<Void>

    init(_ promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    func channelActive(context: ChannelHandlerContext) {
        self.promise.succeed(())
    }
}

@available(OSX 10.14, iOS 12.0, tvOS 12.0, *)
final class EventWaiter<Event: Sendable>: ChannelInboundHandler {
    typealias InboundIn = Any
    typealias InboundOut = Any

    private var eventWaiter: EventLoopPromise<Event>?

    init(_ eventWaiter: EventLoopPromise<Event>) {
        self.eventWaiter = eventWaiter
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? Event {
            var promise = Optional<EventLoopPromise<Event>>.none
            swap(&promise, &self.eventWaiter)
            promise?.succeed(event)
        }
        context.fireUserInboundEventTriggered(event)
    }
}

@available(macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 6, *)
class NIOTSConnectionChannelTests: XCTestCase {
    private var group: NIOTSEventLoopGroup!

    override func setUp() {
        self.group = NIOTSEventLoopGroup()
    }

    override func tearDown() {
        XCTAssertNoThrow(try self.group.syncShutdownGracefully())
    }

    func testConnectingToSocketAddressTraversesPipeline() throws {
        let listener = try NIOTSListenerBootstrap(group: self.group)
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let connectBootstrap = NIOTSConnectionBootstrap(group: self.group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let handler = ConnectRecordingHandler()
                    try channel.pipeline.syncOperations.addHandler(handler)
                    XCTAssertEqual(handler.connectTargets, [])
                    XCTAssertEqual(handler.endpointTargets, [])
                }
            }

        let connection = try connectBootstrap.connect(to: listener.localAddress!).wait()
        defer {
            XCTAssertNoThrow(try connection.close().wait())
        }

        try connection.eventLoop.submit {
            let handler = try connection.pipeline.syncOperations.handler(type: ConnectRecordingHandler.self)
            XCTAssertEqual(handler.connectTargets, [listener.localAddress!])
            XCTAssertEqual(handler.endpointTargets, [])
        }.wait()
    }

    func testConnectingToHostPortSkipsPipeline() throws {
        let listener = try NIOTSListenerBootstrap(group: self.group)
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let connectBootstrap = NIOTSConnectionBootstrap(group: self.group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let connectRecordingHandler = ConnectRecordingHandler()
                    try channel.pipeline.syncOperations.addHandler(connectRecordingHandler)
                    XCTAssertEqual(connectRecordingHandler.connectTargets, [])
                    XCTAssertEqual(connectRecordingHandler.endpointTargets, [])
                }
            }

        let connection = try connectBootstrap.connect(host: "localhost", port: Int(listener.localAddress!.port!)).wait()
        defer {
            XCTAssertNoThrow(try connection.close().wait())
        }

        try connection.eventLoop.submit {
            let connectRecordingHandler = try connection.pipeline.syncOperations.handler(
                type: ConnectRecordingHandler.self
            )
            XCTAssertEqual(connectRecordingHandler.connectTargets, [])
            XCTAssertEqual(
                connectRecordingHandler.endpointTargets,
                [
                    NWEndpoint.hostPort(
                        host: "localhost",
                        port: NWEndpoint.Port(rawValue: UInt16(listener.localAddress!.port!))!
                    )
                ]
            )
        }.wait()
    }

    func testConnectingToEndpointSkipsPipeline() throws {
        let listener = try NIOTSListenerBootstrap(group: self.group)
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let connectBootstrap = NIOTSConnectionBootstrap(group: self.group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let connectRecordingHandler = ConnectRecordingHandler()
                    try channel.pipeline.syncOperations.addHandler(connectRecordingHandler)
                    XCTAssertEqual(connectRecordingHandler.connectTargets, [])
                    XCTAssertEqual(connectRecordingHandler.endpointTargets, [])
                }
            }

        let target = NWEndpoint.hostPort(
            host: "localhost",
            port: NWEndpoint.Port(rawValue: UInt16(listener.localAddress!.port!))!
        )

        let connection = try connectBootstrap.connect(endpoint: target).wait()
        defer {
            XCTAssertNoThrow(try connection.close().wait())
        }

        try connection.eventLoop.submit {
            let connectRecordingHandler = try connection.pipeline.syncOperations.handler(
                type: ConnectRecordingHandler.self
            )
            XCTAssertEqual(connectRecordingHandler.connectTargets, [])
            XCTAssertEqual(connectRecordingHandler.endpointTargets, [target])
        }.wait()
    }

    func testZeroLengthWritesHaveSatisfiedPromises() throws {
        let listener = try NIOTSListenerBootstrap(group: self.group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(FailOnReadHandler())
                }
            }
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let connection = try NIOTSConnectionBootstrap(group: self.group).connect(to: listener.localAddress!).wait()
        defer {
            XCTAssertNoThrow(try connection.close().wait())
        }

        let buffer = connection.allocator.buffer(capacity: 0)
        XCTAssertNoThrow(try connection.writeAndFlush(buffer).wait())
    }

    func testSettingTCPOptionsWholesale() throws {
        let listenerTCPOptions = NWProtocolTCP.Options()
        listenerTCPOptions.disableAckStretching = true

        let connectionTCPOptions = NWProtocolTCP.Options()
        connectionTCPOptions.disableAckStretching = true

        let listener = try NIOTSListenerBootstrap(group: self.group)
            .tcpOptions(listenerTCPOptions)
            .childTCPOptions(connectionTCPOptions)
            .serverChannelInitializer { channel in
                channel.getOption(ChannelOptions.socket(IPPROTO_TCP, TCP_SENDMOREACKS)).map { value in
                    XCTAssertEqual(value, 1)
                }
            }
            .childChannelInitializer { channel in
                channel.getOption(ChannelOptions.socket(IPPROTO_TCP, TCP_SENDMOREACKS)).map { value in
                    XCTAssertEqual(value, 1)
                }
            }
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let connection = try NIOTSConnectionBootstrap(group: self.group)
            .tcpOptions(connectionTCPOptions)
            .channelInitializer { channel in
                channel.getOption(ChannelOptions.socket(IPPROTO_TCP, TCP_SENDMOREACKS)).map { value in
                    XCTAssertEqual(value, 1)
                }
            }
            .connect(to: listener.localAddress!).wait()
        defer {
            XCTAssertNoThrow(try connection.close().wait())
        }

        let buffer = connection.allocator.buffer(capacity: 0)
        XCTAssertNoThrow(try connection.writeAndFlush(buffer).wait())
    }

    func testWatermarkSettingGetting() throws {
        let listener = try NIOTSListenerBootstrap(group: self.group)
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let connection = try NIOTSConnectionBootstrap(group: self.group)
            .connect(to: listener.localAddress!)
            .wait()
        defer {
            XCTAssertNoThrow(try connection.close().wait())
        }

        try connection.getOption(ChannelOptions.writeBufferWaterMark).flatMap { option -> EventLoopFuture<Void> in
            XCTAssertEqual(option.high, 64 * 1024)
            XCTAssertEqual(option.low, 32 * 1024)

            return connection.setOption(
                ChannelOptions.writeBufferWaterMark,
                value: ChannelOptions.Types.WriteBufferWaterMark(low: 1, high: 101)
            )
        }.flatMap {
            connection.getOption(ChannelOptions.writeBufferWaterMark)
        }.map {
            XCTAssertEqual($0.high, 101)
            XCTAssertEqual($0.low, 1)
        }.wait()
    }

    func testWritabilityChangesAfterExceedingWatermarks() throws {
        let listener = try NIOTSListenerBootstrap(group: self.group)
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let writabilities: NIOLockedValueBox<[Bool]> = .init([])
        let connection = try NIOTSConnectionBootstrap(group: self.group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let handler = WritabilityChangedHandler { newValue in
                        writabilities.withLockedValue { $0.append(newValue) }
                    }
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }
            .connect(to: listener.localAddress!)
            .wait()

        // We're going to set some helpful watermarks, and allocate a big buffer.
        XCTAssertNoThrow(
            try connection.setOption(
                ChannelOptions.writeBufferWaterMark,
                value: ChannelOptions.Types.WriteBufferWaterMark(low: 2, high: 2048)
            ).wait()
        )

        // We're going to issue the following pattern of writes:
        // a: 1 byte
        // b: 1 byte
        // c: 2045 bytes
        // d: 1 byte
        // e: 1 byte
        //
        // We will begin by issuing the writes and checking the writeability status of the channel.
        // The channel will remain writable until after the write of e, at which point the channel will
        // become non-writable.
        //
        // Then we will issue a flush. The writes will succeed in order. The channel will remain non-writable
        // until after the promise for d has fired: by the time the promise for e has fired it will be writable
        // again.
        try connection.eventLoop.submit {
            var buffer = connection.allocator.buffer(capacity: 2048)
            buffer.writeBytes(repeatElement(UInt8(4), count: 2048))

            // Pre writing.
            XCTAssertEqual(writabilities.withLockedValue({ $0 }), [])
            XCTAssertTrue(connection.isWritable)

            // Write a. After this write, we are still writable. When this write
            // succeeds, we'll still be not writable.
            connection.write(buffer.getSlice(at: 0, length: 1)).whenComplete { (_: Result<Void, Error>) in
                XCTAssertEqual(writabilities.withLockedValue({ $0 }), [false])
                XCTAssertFalse(connection.isWritable)
            }
            XCTAssertEqual(writabilities.withLockedValue({ $0 }), [])
            XCTAssertTrue(connection.isWritable)

            // Write b. After this write we are still writable. When this write
            // succeeds we'll still be not writable.
            connection.write(buffer.getSlice(at: 0, length: 1)).whenComplete { (_: Result<Void, Error>) in
                XCTAssertEqual(writabilities.withLockedValue({ $0 }), [false])
                XCTAssertFalse(connection.isWritable)
            }
            XCTAssertEqual(writabilities.withLockedValue({ $0 }), [])
            XCTAssertTrue(connection.isWritable)

            // Write c. After this write we are still writable (2047 bytes written).
            // When this write succeeds we'll still be not writable (2 bytes outstanding).
            connection.write(buffer.getSlice(at: 0, length: 2045)).whenComplete { (_: Result<Void, Error>) in
                XCTAssertEqual(writabilities.withLockedValue({ $0 }), [false])
                XCTAssertFalse(connection.isWritable)
            }
            XCTAssertEqual(writabilities.withLockedValue({ $0 }), [])
            XCTAssertTrue(connection.isWritable)

            // Write d. After this write we are still writable (2048 bytes written).
            // When this write succeeds we'll become writable, but critically the promise fires before
            // the state change, so we'll *appear* to be unwritable.
            connection.write(buffer.getSlice(at: 0, length: 1)).whenComplete { (_: Result<Void, Error>) in
                XCTAssertEqual(writabilities.withLockedValue({ $0 }), [false])
                XCTAssertFalse(connection.isWritable)
            }
            XCTAssertEqual(writabilities.withLockedValue({ $0 }), [])
            XCTAssertTrue(connection.isWritable)

            // Write e. After this write we are now not writable (2049 bytes written).
            // When this write succeeds we'll have already been writable, thanks to the previous
            // write.
            connection.write(buffer.getSlice(at: 0, length: 1)).whenComplete { (_: Result<Void, Error>) in
                XCTAssertEqual(writabilities.withLockedValue({ $0 }), [false, true])
                XCTAssertTrue(connection.isWritable)

                // We close after this succeeds.
                connection.close(promise: nil)
            }
            XCTAssertEqual(writabilities.withLockedValue({ $0 }), [false])
            XCTAssertFalse(connection.isWritable)
        }.wait()

        // Now we're going to flush. This should fire all the writes.
        connection.flush()
        XCTAssertNoThrow(try connection.closeFuture.wait())

        // Ok, check that the writability changes worked.
        XCTAssertEqual(writabilities.withLockedValue({ $0 }), [false, true])
    }

    func testWritabilityChangesAfterChangingWatermarks() throws {
        let listener = try NIOTSListenerBootstrap(group: self.group)
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let writabilities: NIOLockedValueBox<[Bool]> = .init([])
        let connection = try NIOTSConnectionBootstrap(group: self.group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let handler = WritabilityChangedHandler { newValue in
                        writabilities.withLockedValue({ $0.append(newValue) })
                    }
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }
            .connect(to: listener.localAddress!)
            .wait()
        defer {
            XCTAssertNoThrow(try connection.close().wait())
        }

        // We're going to issue a 256-byte write. This write will not cause any change in channel writability
        // state.
        //
        // Then we're going to set the high watermark to 256, and the low to 128. This will not change channel
        // writability state.
        //
        // Then we're going to set the high watermark to 255 and the low to 128. This will make the channel
        // not writable.
        //
        // Then we're going to set the high watermark to 256, and the low to 128. This will not change the
        // channel writability state.
        //
        // Then we're going to set the high watermark to 1024, and the low to 256. This will not change the
        // channel writability state.
        //
        // Then we're going to set the high watermark to 1024, and the low to 257. This will make the channel
        // writable again.
        //
        // Then we're going to set the high watermark to 1024, and the low to 256. This will change nothing.
        try connection.eventLoop.submit {
            // We're going to allocate a buffer.
            var buffer = connection.allocator.buffer(capacity: 256)
            buffer.writeBytes(repeatElement(UInt8(4), count: 256))

            // Pre changes.
            XCTAssertEqual(writabilities.withLockedValue({ $0 }), [])
            XCTAssertTrue(connection.isWritable)

            // Write. No writability change.
            connection.write(buffer, promise: nil)
            XCTAssertEqual(writabilities.withLockedValue({ $0 }), [])
            XCTAssertTrue(connection.isWritable)
        }.wait()

        try connection.setOption(
            ChannelOptions.writeBufferWaterMark,
            value: ChannelOptions.Types.WriteBufferWaterMark(low: 128, high: 256)
        ).flatMap {
            // High to 256, low to 128. No writability change.
            XCTAssertEqual(writabilities.withLockedValue({ $0 }), [])
            XCTAssertTrue(connection.isWritable)

            return connection.setOption(
                ChannelOptions.writeBufferWaterMark,
                value: ChannelOptions.Types.WriteBufferWaterMark(low: 128, high: 255)
            )
        }.flatMap {
            // High to 255, low to 127. Channel becomes not writable.
            XCTAssertEqual(writabilities.withLockedValue({ $0 }), [false])
            XCTAssertFalse(connection.isWritable)

            return connection.setOption(
                ChannelOptions.writeBufferWaterMark,
                value: ChannelOptions.Types.WriteBufferWaterMark(low: 128, high: 256)
            )
        }.flatMap {
            // High back to 256, low to 128. No writability change.
            XCTAssertEqual(writabilities.withLockedValue({ $0 }), [false])
            XCTAssertFalse(connection.isWritable)

            return connection.setOption(
                ChannelOptions.writeBufferWaterMark,
                value: ChannelOptions.Types.WriteBufferWaterMark(low: 256, high: 1024)
            )
        }.flatMap {
            // High to 1024, low to 128. No writability change.
            XCTAssertEqual(writabilities.withLockedValue({ $0 }), [false])
            XCTAssertFalse(connection.isWritable)

            return connection.setOption(
                ChannelOptions.writeBufferWaterMark,
                value: ChannelOptions.Types.WriteBufferWaterMark(low: 257, high: 1024)
            )
        }.flatMap {
            // Low to 257, channel becomes writable again.
            XCTAssertEqual(writabilities.withLockedValue({ $0 }), [false, true])
            XCTAssertTrue(connection.isWritable)

            return connection.setOption(
                ChannelOptions.writeBufferWaterMark,
                value: ChannelOptions.Types.WriteBufferWaterMark(low: 256, high: 1024)
            )
        }.map {
            // Low back to 256, no writability change.
            XCTAssertEqual(writabilities.withLockedValue({ $0 }), [false, true])
            XCTAssertTrue(connection.isWritable)
        }.wait()
    }

    func testSettingGettingReuseaddr() throws {
        let listener = try NIOTSListenerBootstrap(group: self.group).bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }
        let connection = try NIOTSConnectionBootstrap(group: self.group)
            .connect(to: listener.localAddress!)
            .wait()
        defer {
            XCTAssertNoThrow(try connection.close().wait())
        }

        XCTAssertEqual(0, try connection.getOption(ChannelOptions.socket(SOL_SOCKET, SO_REUSEADDR)).wait())
        XCTAssertNoThrow(try connection.setOption(ChannelOptions.socket(SOL_SOCKET, SO_REUSEADDR), value: 5).wait())
        XCTAssertEqual(1, try connection.getOption(ChannelOptions.socket(SOL_SOCKET, SO_REUSEADDR)).wait())
        XCTAssertNoThrow(try connection.setOption(ChannelOptions.socket(SOL_SOCKET, SO_REUSEADDR), value: 0).wait())
        XCTAssertEqual(0, try connection.getOption(ChannelOptions.socket(SOL_SOCKET, SO_REUSEADDR)).wait())
    }

    func testSettingGettingReuseport() throws {
        let listener = try NIOTSListenerBootstrap(group: self.group).bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }
        let connection = try NIOTSConnectionBootstrap(group: self.group)
            .connect(to: listener.localAddress!)
            .wait()
        defer {
            XCTAssertNoThrow(try connection.close().wait())
        }

        XCTAssertEqual(0, try connection.getOption(ChannelOptions.socket(SOL_SOCKET, SO_REUSEPORT)).wait())
        XCTAssertNoThrow(try connection.setOption(ChannelOptions.socket(SOL_SOCKET, SO_REUSEPORT), value: 5).wait())
        XCTAssertEqual(1, try connection.getOption(ChannelOptions.socket(SOL_SOCKET, SO_REUSEPORT)).wait())
        XCTAssertNoThrow(try connection.setOption(ChannelOptions.socket(SOL_SOCKET, SO_REUSEPORT), value: 0).wait())
        XCTAssertEqual(0, try connection.getOption(ChannelOptions.socket(SOL_SOCKET, SO_REUSEPORT)).wait())
    }

    func testErrorsInChannelSetupAreFine() throws {
        struct MyError: Error {}

        let listener = try NIOTSListenerBootstrap(group: self.group)
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let connectFuture = NIOTSConnectionBootstrap(group: self.group)
            .channelInitializer { channel in channel.eventLoop.makeFailedFuture(MyError()) }
            .connect(to: listener.localAddress!)

        do {
            let conn = try connectFuture.wait()
            XCTAssertNoThrow(try conn.close().wait())
            XCTFail("Did not throw")
        } catch is MyError {
            // fine
        } catch {
            XCTFail("Unexpected error")
        }
    }

    func testEarlyExitForWaitingChannel() throws {
        let connectFuture = NIOTSConnectionBootstrap(group: self.group)
            .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
            .connect(to: try SocketAddress(unixDomainSocketPath: "/this/path/definitely/doesnt/exist"))

        do {
            let conn = try connectFuture.wait()
            XCTAssertNoThrow(try conn.close().wait())
            XCTFail("Did not throw")
        } catch is NWError {
            // fine
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testEarlyExitCanBeSetInWaitingState() throws {
        let connectFuture = NIOTSConnectionBootstrap(group: self.group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(DisableWaitingAfterConnect())
                }
            }.connect(to: try SocketAddress(unixDomainSocketPath: "/this/path/definitely/doesnt/exist"))

        do {
            let conn = try connectFuture.wait()
            XCTAssertNoThrow(try conn.close().wait())
            XCTFail("Did not throw")
        } catch is NWError {
            // fine
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testSettingWaitForConnectivityDoesntCloseImmediately() throws {
        enum Reason {
            case timedClose
            case autoClose
        }

        // We want a single loop for all this to enforce serialization.
        let chosenLoop = self.group.next()
        let closedPromise = chosenLoop.makePromise(of: Reason.self)

        _ = NIOTSConnectionBootstrap(group: chosenLoop)
            .channelInitializer { channel in
                try! channel.pipeline.syncOperations.addHandler(EnableWaitingAfterWaiting())

                channel.eventLoop.scheduleTask(in: .milliseconds(500)) {
                    channel.close(promise: nil)
                    closedPromise.succeed(.timedClose)
                }

                channel.closeFuture.whenComplete { _ in
                    closedPromise.succeed(.autoClose)
                }

                return channel.eventLoop.makeSucceededVoidFuture()
            }.connect(to: try SocketAddress(unixDomainSocketPath: "/this/path/definitely/doesnt/exist"))

        let result = try closedPromise.futureResult.wait()
        XCTAssertEqual(result, .timedClose)
    }

    func testCanObserveValueOfDisableWaiting() throws {
        let listener = try NIOTSListenerBootstrap(group: self.group)
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let connectFuture = NIOTSConnectionBootstrap(group: self.group)
            .channelInitializer { channel in
                channel.getOption(NIOTSChannelOptions.waitForActivity).map { value in
                    XCTAssertTrue(value)
                }.flatMap {
                    channel.setOption(NIOTSChannelOptions.waitForActivity, value: false)
                }.flatMap {
                    channel.getOption(NIOTSChannelOptions.waitForActivity)
                }.map { value in
                    XCTAssertFalse(value)
                }
            }.connect(to: listener.localAddress!)

        let conn = try connectFuture.wait()
        XCTAssertNoThrow(try conn.close().wait())
    }

    func testCanObserveValueOfEnablePeerToPeer() throws {
        let listener = try NIOTSListenerBootstrap(group: self.group)
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let connectFuture = NIOTSConnectionBootstrap(group: self.group)
            .channelInitializer { channel in
                channel.getOption(NIOTSChannelOptions.enablePeerToPeer).map { value in
                    XCTAssertFalse(value)
                }.flatMap {
                    channel.setOption(NIOTSChannelOptions.enablePeerToPeer, value: true)
                }.flatMap {
                    channel.getOption(NIOTSChannelOptions.enablePeerToPeer)
                }.map { value in
                    XCTAssertTrue(value)
                }
            }.connect(to: listener.localAddress!)

        let conn = try connectFuture.wait()
        XCTAssertNoThrow(try conn.close().wait())
    }

    func testCanSafelyInvokeActiveFromMultipleThreads() throws {
        // This test exists to trigger TSAN violations if we screw things up.
        let listener = try NIOTSListenerBootstrap(group: self.group)
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let activePromise: EventLoopPromise<Void> = self.group.next().makePromise()

        let channel = try NIOTSConnectionBootstrap(group: self.group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        PromiseOnActiveHandler(activePromise)
                    )
                }
            }.connect(to: listener.localAddress!).wait()

        XCTAssertNoThrow(try activePromise.futureResult.wait())
        XCTAssertTrue(channel.isActive)

        XCTAssertNoThrow(try channel.close().wait())
    }

    func testConnectingChannelsOnShutdownEventLoopsFails() throws {
        let temporaryGroup = NIOTSEventLoopGroup()
        XCTAssertNoThrow(try temporaryGroup.syncShutdownGracefully())

        let bootstrap = NIOTSConnectionBootstrap(group: temporaryGroup)

        do {
            _ = try bootstrap.connect(host: "localhost", port: 12345).wait()
        } catch EventLoopError.shutdown {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAutoReadTraversesThePipeline() throws {
        // This test is driven entirely by a channel handler inserted into the client channel.
        final class TestHandler: ChannelDuplexHandler {
            typealias InboundIn = ByteBuffer
            typealias OutboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer

            var readCount = 0

            private let testCompletePromise: EventLoopPromise<Void>

            init(testCompletePromise: EventLoopPromise<Void>) {
                self.testCompletePromise = testCompletePromise
            }

            func read(context: ChannelHandlerContext) {
                self.readCount += 1
                context.read()
            }

            func channelActive(context: ChannelHandlerContext) {
                var buffer = context.channel.allocator.buffer(capacity: 12)
                buffer.writeString("Hello, world!")

                context.writeAndFlush(self.wrapOutboundOut(buffer), promise: nil)
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                var buffer = self.unwrapInboundIn(data)
                if buffer.readString(length: buffer.readableBytes) == "Hello, world!" {
                    self.testCompletePromise.succeed(())
                }
            }
        }

        let testCompletePromise = self.group.next().makePromise(of: Void.self)
        let listener = try assertNoThrowWithValue(
            NIOTSListenerBootstrap(group: self.group)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(EchoHandler())
                    }
                }
                .bind(host: "localhost", port: 0).wait()
        )
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let connectBootstrap = NIOTSConnectionBootstrap(group: self.group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        TestHandler(testCompletePromise: testCompletePromise)
                    )
                }
            }

        let connection = try assertNoThrowWithValue(connectBootstrap.connect(to: listener.localAddress!).wait())
        defer {
            XCTAssertNoThrow(try connection.close().wait())
        }

        // Let the test run.
        XCTAssertNoThrow(try testCompletePromise.futureResult.wait())

        // When the test is completed, we expect the following:
        //
        // 1. channelActive, which leads to a write and flush.
        // 2. read, triggered by autoRead.
        // 3. channelRead, enabled by the read above, which completes our promise.
        // 4. IN THE SAME EVENT LOOP TICK, read(), triggered by autoRead.
        //
        // Thus, once the test has completed we can enter the event loop and check the read count.
        // We expect 2.
        XCTAssertNoThrow(
            try connection.eventLoop.submit {
                let handler = try connection.pipeline.syncOperations.handler(type: TestHandler.self)
                XCTAssertEqual(handler.readCount, 2)
            }.wait()
        )
    }

    func testLoadingAddressesInMultipleQueues() throws {
        let listener = try NIOTSListenerBootstrap(group: self.group)
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let ourSyncQueue = DispatchQueue(label: "ourSyncQueue")

        let workFuture = NIOTSConnectionBootstrap(group: self.group).connect(to: listener.localAddress!).map {
            channel -> Channel in
            XCTAssertTrue(channel.eventLoop.inEventLoop)

            ourSyncQueue.sync {
                XCTAssertFalse(channel.eventLoop.inEventLoop)

                // These will crash before we apply our fix.
                XCTAssertNotNil(channel.localAddress)
                XCTAssertNotNil(channel.remoteAddress)
            }

            return channel
        }.flatMap { $0.close() }

        XCTAssertNoThrow(try workFuture.wait())
    }

    func testConnectingInvolvesWaiting() throws {
        let loop = self.group.next()
        let eventPromise = loop.makePromise(of: NIOTSNetworkEvents.WaitingForConnectivity.self)

        // 5s is the worst-case test time: normally it'll be faster as we don't wait for this.
        let connectBootstrap = NIOTSConnectionBootstrap(group: loop)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let eventRecordingHandler = EventWaiter<NIOTSNetworkEvents.WaitingForConnectivity>(eventPromise)
                    try channel.pipeline.syncOperations.addHandler(eventRecordingHandler)
                }
            }
            .connectTimeout(.seconds(5))

        // We choose 443 here to avoid triggering Private Relay, which can do all kinds of weird stuff to this test.
        let target = NWEndpoint.hostPort(host: "example.invalid", port: 443)

        // We don't wait here, as the connect attempt should timeout. If it doesn't, we'll close it.
        connectBootstrap.connect(endpoint: target).whenSuccess { conn in
            XCTFail("DNS resolution should have returned NXDOMAIN but did not: DNS hijacking forces this test to fail")
            conn.close(promise: nil)
        }

        // We don't actually investigate this because the error is going to be very OS specific. It just mustn't
        // throw
        XCTAssertNoThrow(try eventPromise.futureResult.wait())
    }

    func testConnectingToEmptyStringErrors() throws {
        let connectBootstrap = NIOTSConnectionBootstrap(group: self.group)
        XCTAssertThrowsError(try connectBootstrap.connect(host: "", port: 80).wait()) { error in
            XCTAssertTrue(error is NIOTSErrors.InvalidHostname)
        }
    }

    func testSyncOptionsAreSupported() throws {
        @Sendable func testSyncOptions(_ channel: Channel) {
            if let sync = channel.syncOptions {
                do {
                    let autoRead = try sync.getOption(ChannelOptions.autoRead)
                    try sync.setOption(ChannelOptions.autoRead, value: !autoRead)
                    XCTAssertNotEqual(autoRead, try sync.getOption(ChannelOptions.autoRead))
                } catch {
                    XCTFail("Could not get/set autoRead: \(error)")
                }
            } else {
                XCTFail("\(channel) unexpectedly returned nil syncOptions")
            }
        }

        let listener = try NIOTSListenerBootstrap(group: self.group)
            .childChannelInitializer { channel in
                testSyncOptions(channel)
                return channel.eventLoop.makeSucceededVoidFuture()
            }
            .bind(host: "localhost", port: 0)
            .wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let connection = try NIOTSConnectionBootstrap(group: self.group)
            .channelInitializer { channel in
                testSyncOptions(channel)
                return channel.eventLoop.makeSucceededVoidFuture()
            }
            .connect(to: listener.localAddress!)
            .wait()
        XCTAssertNoThrow(try connection.close().wait())
    }

    func testErrorIsForwardedFromFailedConnectionState() throws {
        final class ForwardErrorHandler: ChannelDuplexHandler {
            typealias OutboundIn = ByteBuffer
            typealias InboundIn = ByteBuffer

            private let testCompletePromise: EventLoopPromise<Error>
            let listenerChannel: Channel

            init(testCompletePromise: EventLoopPromise<Error>, listenerChannel: Channel) {
                self.testCompletePromise = testCompletePromise
                self.listenerChannel = listenerChannel
            }

            func channelActive(context: ChannelHandlerContext) {
                listenerChannel
                    .close()
                    .assumeIsolated()
                    .whenSuccess { _ in
                        _ = context.channel.write(ByteBuffer(data: Data()))
                    }
            }

            func errorCaught(context: ChannelHandlerContext, error: Error) {
                let error = error as? ChannelError
                XCTAssertNotEqual(error, ChannelError.eof)
                XCTAssertEqual(error, ChannelError.ioOnClosedChannel)
                XCTAssertNotNil(error)
                testCompletePromise.succeed(error!)
            }
        }

        let listener = try NIOTSListenerBootstrap(group: self.group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeSucceededVoidFuture()
            }
            .bind(host: "localhost", port: 0)
            .wait()

        let testCompletePromise = self.group.next().makePromise(of: Error.self)
        let connection = try NIOTSConnectionBootstrap(group: self.group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        ForwardErrorHandler(
                            testCompletePromise: testCompletePromise,
                            listenerChannel: listener
                        )
                    )
                }
            }
            .connect(to: listener.localAddress!)
            .wait()
        XCTAssertNoThrow(try connection.close().wait())
        XCTAssertNoThrow(try testCompletePromise.futureResult.wait())
    }

    func testCanExtractTheConnection() throws {
        guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) else {
            throw XCTSkip("Option not available")
        }

        let listener = try NIOTSListenerBootstrap(group: self.group)
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        _ = try NIOTSConnectionBootstrap(group: self.group)
            .channelInitializer { channel in
                let conn = try! channel.syncOptions!.getOption(NIOTSChannelOptions.connection)
                XCTAssertNil(conn)
                return channel.eventLoop.makeSucceededVoidFuture()
            }.connect(to: listener.localAddress!).flatMap {
                $0.getOption(NIOTSChannelOptions.connection)
            }.always { result in
                switch result {
                case .success(let connection):
                    // Make sure we unwrap the connection.
                    XCTAssertNotNil(connection)
                case .failure(let error):
                    XCTFail("Unexpected error: \(error)")
                }
            }.wait()
    }
}
#endif
