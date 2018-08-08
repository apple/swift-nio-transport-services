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
import XCTest
import Network
import NIO
import NIOTransportServices


final class ConnectRecordingHandler: ChannelOutboundHandler {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    var connectTargets: [SocketAddress] = []
    var endpointTargets: [NWEndpoint] = []

    func connect(ctx: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        self.connectTargets.append(address)
        ctx.connect(to: address, promise: promise)
    }

    func triggerUserOutboundEvent(ctx: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        switch event {
        case let evt as NIOTSNetworkEvents.ConnectToNWEndpoint:
            self.endpointTargets.append(evt.endpoint)
        default:
            break
        }
        ctx.triggerUserOutboundEvent(event, promise: promise)
    }
}


final class FailOnReadHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        XCTFail("Must not read")
        ctx.fireChannelRead(data)
    }
}


final class WritabilityChangedHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let cb: (Bool) -> Void

    init(_ cb: @escaping (Bool) -> Void) {
        self.cb = cb
    }

    func channelWritabilityChanged(ctx: ChannelHandlerContext) {
        self.cb(ctx.channel.isWritable)
    }
}


class NIOTSConnectionChannelTests: XCTestCase {
    private var group: NIOTSEventLoopGroup!

    override func setUp() {
        self.group = NIOTSEventLoopGroup()
    }

    override func tearDown() {
        XCTAssertNoThrow(try self.group.syncShutdownGracefully())
    }

    func testConnectingToSocketAddressTraversesPipeline() throws {
        let connectRecordingHandler = ConnectRecordingHandler()
        let listener = try NIOTSListenerBootstrap(group: self.group)
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let connectBootstrap = NIOTSConnectionBootstrap(group: self.group)
            .channelInitializer { channel in channel.pipeline.add(handler: connectRecordingHandler) }
        XCTAssertEqual(connectRecordingHandler.connectTargets, [])
        XCTAssertEqual(connectRecordingHandler.endpointTargets, [])

        let connection = try connectBootstrap.connect(to: listener.localAddress!).wait()
        defer {
            XCTAssertNoThrow(try connection.close().wait())
        }

        try connection.eventLoop.submit {
            XCTAssertEqual(connectRecordingHandler.connectTargets, [listener.localAddress!])
            XCTAssertEqual(connectRecordingHandler.endpointTargets, [])
        }.wait()
    }

    func testConnectingToHostPortSkipsPipeline() throws {
        let connectRecordingHandler = ConnectRecordingHandler()
        let listener = try NIOTSListenerBootstrap(group: self.group)
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let connectBootstrap = NIOTSConnectionBootstrap(group: self.group)
            .channelInitializer { channel in channel.pipeline.add(handler: connectRecordingHandler) }
        XCTAssertEqual(connectRecordingHandler.connectTargets, [])
        XCTAssertEqual(connectRecordingHandler.endpointTargets, [])

        let connection = try connectBootstrap.connect(host: "localhost", port: Int(listener.localAddress!.port!)).wait()
        defer {
            XCTAssertNoThrow(try connection.close().wait())
        }

        try connection.eventLoop.submit {
            XCTAssertEqual(connectRecordingHandler.connectTargets, [])
            XCTAssertEqual(connectRecordingHandler.endpointTargets, [NWEndpoint.hostPort(host: "localhost", port: NWEndpoint.Port(rawValue: listener.localAddress!.port!)!)])
        }.wait()
    }

    func testConnectingToEndpointSkipsPipeline() throws {
        let connectRecordingHandler = ConnectRecordingHandler()
        let listener = try NIOTSListenerBootstrap(group: self.group)
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let connectBootstrap = NIOTSConnectionBootstrap(group: self.group)
            .channelInitializer { channel in channel.pipeline.add(handler: connectRecordingHandler) }
        XCTAssertEqual(connectRecordingHandler.connectTargets, [])
        XCTAssertEqual(connectRecordingHandler.endpointTargets, [])

        let target = NWEndpoint.hostPort(host: "localhost", port: NWEndpoint.Port(rawValue: listener.localAddress!.port!)!)

        let connection = try connectBootstrap.connect(endpoint: target).wait()
        defer {
            XCTAssertNoThrow(try connection.close().wait())
        }

        try connection.eventLoop.submit {
            XCTAssertEqual(connectRecordingHandler.connectTargets, [])
            XCTAssertEqual(connectRecordingHandler.endpointTargets, [target])
        }.wait()
    }

    func testZeroLengthWritesHaveSatisfiedPromises() throws {
        let listener = try NIOTSListenerBootstrap(group: self.group)
            .childChannelInitializer { channel in channel.pipeline.add(handler: FailOnReadHandler())}
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
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.disableAckStretching = true


        let listener = try NIOTSListenerBootstrap(group: self.group)
            .tcpOptions(tcpOptions)
            .serverChannelInitializer { channel in
                channel.getOption(option: ChannelOptions.socket(IPPROTO_TCP, TCP_SENDMOREACKS)).map { value in
                    XCTAssertEqual(value, 1)
                }
            }
            .childChannelInitializer { channel in
                channel.getOption(option: ChannelOptions.socket(IPPROTO_TCP, TCP_SENDMOREACKS)).map { value in
                    XCTAssertEqual(value, 1)
                }
            }
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let connection = try NIOTSConnectionBootstrap(group: self.group)
            .tcpOptions(tcpOptions)
            .channelInitializer { channel in
                channel.getOption(option: ChannelOptions.socket(IPPROTO_TCP, TCP_SENDMOREACKS)).map { value in
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

        try connection.getOption(option: ChannelOptions.writeBufferWaterMark).then { option -> EventLoopFuture<Void> in
            XCTAssertEqual(option.high, 64 * 1024)
            XCTAssertEqual(option.low, 32 * 1024)

            return connection.setOption(option: ChannelOptions.writeBufferWaterMark, value: WriteBufferWaterMark(low: 1, high: 101))
        }.then {
            connection.getOption(option: ChannelOptions.writeBufferWaterMark)
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

        var writabilities = [Bool]()
        let handler = WritabilityChangedHandler { newValue in
            writabilities.append(newValue)
        }

        let connection = try NIOTSConnectionBootstrap(group: self.group)
            .channelInitializer { channel in channel.pipeline.add(handler: handler) }
            .connect(to: listener.localAddress!)
            .wait()

        // We're going to set some helpful watermarks, and allocate a big buffer.
        XCTAssertNoThrow(try connection.setOption(option: ChannelOptions.writeBufferWaterMark, value: WriteBufferWaterMark(low: 2, high: 2048)).wait())
        var buffer = connection.allocator.buffer(capacity: 2048)
        buffer.write(bytes: repeatElement(UInt8(4), count: 2048))

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
            // Pre writing.
            XCTAssertEqual(writabilities, [])
            XCTAssertTrue(connection.isWritable)

            // Write a. After this write, we are still writable. When this write
            // succeeds, we'll still be not writable.
            connection.write(buffer.getSlice(at: 0, length: 1)).whenComplete {
                XCTAssertEqual(writabilities, [false])
                XCTAssertFalse(connection.isWritable)
            }
            XCTAssertEqual(writabilities, [])
            XCTAssertTrue(connection.isWritable)

            // Write b. After this write we are still writable. When this write
            // succeeds we'll still be not writable.
            connection.write(buffer.getSlice(at: 0, length: 1)).whenComplete {
                XCTAssertEqual(writabilities, [false])
                XCTAssertFalse(connection.isWritable)
            }
            XCTAssertEqual(writabilities, [])
            XCTAssertTrue(connection.isWritable)

            // Write c. After this write we are still writable (2047 bytes written).
            // When this write succeeds we'll still be not writable (2 bytes outstanding).
            connection.write(buffer.getSlice(at: 0, length: 2045)).whenComplete {
                XCTAssertEqual(writabilities, [false])
                XCTAssertFalse(connection.isWritable)
            }
            XCTAssertEqual(writabilities, [])
            XCTAssertTrue(connection.isWritable)

            // Write d. After this write we are still writable (2048 bytes written).
            // When this write succeeds we'll become writable, but critically the promise fires before
            // the state change, so we'll *appear* to be unwritable.
            connection.write(buffer.getSlice(at: 0, length: 1)).whenComplete {
                XCTAssertEqual(writabilities, [false])
                XCTAssertFalse(connection.isWritable)
            }
            XCTAssertEqual(writabilities, [])
            XCTAssertTrue(connection.isWritable)

            // Write e. After this write we are now not writable (2049 bytes written).
            // When this write succeeds we'll have already been writable, thanks to the previous
            // write.
            connection.write(buffer.getSlice(at: 0, length: 1)).whenComplete {
                XCTAssertEqual(writabilities, [false, true])
                XCTAssertTrue(connection.isWritable)

                // We close after this succeeds.
                connection.close(promise: nil)
            }
            XCTAssertEqual(writabilities, [false])
            XCTAssertFalse(connection.isWritable)
        }.wait()

        // Now we're going to flush. This should fire all the writes.
        connection.flush()
        XCTAssertNoThrow(try connection.closeFuture.wait())

        // Ok, check that the writability changes worked.
        XCTAssertEqual(writabilities, [false, true])
    }

    func testWritabilityChangesAfterChangingWatermarks() throws {
        let listener = try NIOTSListenerBootstrap(group: self.group)
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        var writabilities = [Bool]()
        let handler = WritabilityChangedHandler { newValue in
            writabilities.append(newValue)
        }

        let connection = try NIOTSConnectionBootstrap(group: self.group)
            .channelInitializer { channel in channel.pipeline.add(handler: handler) }
            .connect(to: listener.localAddress!)
            .wait()
        defer {
            XCTAssertNoThrow(try connection.close().wait())
        }

        // We're going to allocate a buffer.
        var buffer = connection.allocator.buffer(capacity: 256)
        buffer.write(bytes: repeatElement(UInt8(4), count: 256))

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
            // Pre changes.
            XCTAssertEqual(writabilities, [])
            XCTAssertTrue(connection.isWritable)

            // Write. No writability change.
            connection.write(buffer, promise: nil)
            XCTAssertEqual(writabilities, [])
            XCTAssertTrue(connection.isWritable)
        }.wait()

        try connection.setOption(option: ChannelOptions.writeBufferWaterMark, value: WriteBufferWaterMark(low: 128, high: 256)).then {
            // High to 256, low to 128. No writability change.
            XCTAssertEqual(writabilities, [])
            XCTAssertTrue(connection.isWritable)

            return connection.setOption(option: ChannelOptions.writeBufferWaterMark, value: WriteBufferWaterMark(low: 128, high: 255))
        }.then {
            // High to 255, low to 127. Channel becomes not writable.
            XCTAssertEqual(writabilities, [false])
            XCTAssertFalse(connection.isWritable)

            return connection.setOption(option: ChannelOptions.writeBufferWaterMark, value: WriteBufferWaterMark(low: 128, high: 256))
        }.then {
            // High back to 256, low to 128. No writability change.
            XCTAssertEqual(writabilities, [false])
            XCTAssertFalse(connection.isWritable)

            return connection.setOption(option: ChannelOptions.writeBufferWaterMark, value: WriteBufferWaterMark(low: 256, high: 1024))
        }.then {
            // High to 1024, low to 128. No writability change.
            XCTAssertEqual(writabilities, [false])
            XCTAssertFalse(connection.isWritable)

            return connection.setOption(option: ChannelOptions.writeBufferWaterMark, value: WriteBufferWaterMark(low: 257, high: 1024))
        }.then {
            // Low to 257, channel becomes writable again.
            XCTAssertEqual(writabilities, [false, true])
            XCTAssertTrue(connection.isWritable)

            return connection.setOption(option: ChannelOptions.writeBufferWaterMark, value: WriteBufferWaterMark(low: 256, high: 1024))
        }.map {
            // Low back to 256, no writability change.
            XCTAssertEqual(writabilities, [false, true])
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

        XCTAssertEqual(0, try connection.getOption(option: ChannelOptions.socket(SOL_SOCKET, SO_REUSEADDR)).wait())
        XCTAssertNoThrow(try connection.setOption(option: ChannelOptions.socket(SOL_SOCKET, SO_REUSEADDR), value: 5).wait())
        XCTAssertEqual(1, try connection.getOption(option: ChannelOptions.socket(SOL_SOCKET, SO_REUSEADDR)).wait())
        XCTAssertNoThrow(try connection.setOption(option: ChannelOptions.socket(SOL_SOCKET, SO_REUSEADDR), value: 0).wait())
        XCTAssertEqual(0, try connection.getOption(option: ChannelOptions.socket(SOL_SOCKET, SO_REUSEADDR)).wait())
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

        XCTAssertEqual(0, try connection.getOption(option: ChannelOptions.socket(SOL_SOCKET, SO_REUSEPORT)).wait())
        XCTAssertNoThrow(try connection.setOption(option: ChannelOptions.socket(SOL_SOCKET, SO_REUSEPORT), value: 5).wait())
        XCTAssertEqual(1, try connection.getOption(option: ChannelOptions.socket(SOL_SOCKET, SO_REUSEPORT)).wait())
        XCTAssertNoThrow(try connection.setOption(option: ChannelOptions.socket(SOL_SOCKET, SO_REUSEPORT), value: 0).wait())
        XCTAssertEqual(0, try connection.getOption(option: ChannelOptions.socket(SOL_SOCKET, SO_REUSEPORT)).wait())
    }

    func testErrorsInChannelSetupAreFine() throws {
        struct MyError: Error { }

        let listener = try NIOTSListenerBootstrap(group: self.group)
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let connectFuture = NIOTSConnectionBootstrap(group: self.group)
            .channelInitializer { channel in channel.eventLoop.newFailedFuture(error: MyError()) }
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
}
