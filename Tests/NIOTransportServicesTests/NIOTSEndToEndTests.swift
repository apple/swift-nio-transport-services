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
import NIOCore
import NIOTransportServices
import Foundation
import Network
import NIOConcurrencyHelpers

func assertNoThrowWithValue<T>(
    _ body: @autoclosure () throws -> T,
    defaultValue: T? = nil,
    message: String? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    do {
        return try body()
    } catch {
        XCTFail("\(message.map { $0 + ": " } ?? "")unexpected error \(error) thrown", file: (file), line: line)
        if let defaultValue = defaultValue {
            return defaultValue
        } else {
            throw error
        }
    }
}

final class EchoHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    typealias OutboundOut = Any

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.write(data, promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }
}

final class ReadExpecter: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    struct DidNotReadError: Error {}

    private let readPromise: EventLoopPromise<Void>
    private var cumulationBuffer: ByteBuffer?
    private let expectedRead: ByteBuffer

    init(expecting: ByteBuffer, readPromise: EventLoopPromise<Void>) {
        self.readPromise = readPromise
        self.cumulationBuffer = nil
        self.expectedRead = expecting
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.readPromise.fail(DidNotReadError())
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = self.unwrapInboundIn(data)
        self.cumulationBuffer.setOrWriteBuffer(&bytes)
        self.maybeFulfillPromise()
    }

    private func maybeFulfillPromise() {
        guard self.cumulationBuffer == self.expectedRead else { return }
        self.readPromise.succeed(())
    }
}

final class CloseOnActiveHandler: ChannelInboundHandler {
    typealias InboundIn = Never
    typealias OutboundOut = Never

    func channelActive(context: ChannelHandlerContext) {
        context.close(promise: nil)
    }
}

final class HalfCloseHandler: ChannelInboundHandler {
    typealias InboundIn = Never
    typealias InboundOut = Never

    private let halfClosedPromise: EventLoopPromise<Void>
    private var alreadyHalfClosed = false
    private var closed = false

    init(_ halfClosedPromise: EventLoopPromise<Void>) {
        self.halfClosedPromise = halfClosedPromise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case ChannelEvent.inputClosed:
            XCTAssertFalse(self.alreadyHalfClosed)
            XCTAssertFalse(self.closed)
            self.alreadyHalfClosed = true
            self.halfClosedPromise.succeed(())

            context.close(mode: .output, promise: nil)
        default:
            break
        }

        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        XCTAssertTrue(self.alreadyHalfClosed)
        XCTAssertFalse(self.closed)
        self.closed = true
    }
}

final class FailOnHalfCloseHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case ChannelEvent.inputClosed:
            XCTFail("Must not receive half-closure")
            context.close(promise: nil)
        default:
            break
        }

        context.fireUserInboundEventTriggered(event)
    }
}

final class WaitForActiveHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let activePromise: EventLoopPromise<Channel>

    init(_ promise: EventLoopPromise<Channel>) {
        self.activePromise = promise
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive {
            self.activePromise.succeed(context.channel)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        self.activePromise.succeed(context.channel)
    }
}

extension Channel {
    /// Expect that the given bytes will be received.
    func expectRead(_ bytes: ByteBuffer) -> EventLoopFuture<Void> {
        let readPromise = self.eventLoop.makePromise(of: Void.self)
        return self.eventLoop.submit {
            let expecter = ReadExpecter(expecting: bytes, readPromise: readPromise)
            try self.pipeline.syncOperations.addHandler(expecter)
        }.flatMap {
            readPromise.futureResult
        }
    }
}

extension ByteBufferAllocator {
    func bufferFor(string: String) -> ByteBuffer {
        var buffer = self.buffer(capacity: string.count)
        buffer.writeString(string)
        return buffer
    }
}

@available(macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 6, *)
class NIOTSEndToEndTests: XCTestCase {
    private var group: NIOTSEventLoopGroup!

    override func setUp() {
        self.group = NIOTSEventLoopGroup()
    }

    override func tearDown() {
        XCTAssertNoThrow(try self.group.syncShutdownGracefully())
    }

    func testSimpleListener() throws {
        let listener = try NIOTSListenerBootstrap(group: self.group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(EchoHandler())
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

        let buffer = connection.allocator.bufferFor(string: "hello, world!")
        let completeFuture = connection.expectRead(buffer)
        connection.writeAndFlush(buffer, promise: nil)
        XCTAssertNoThrow(try completeFuture.wait())
    }

    func testNWExistingListener() throws {
        let nwListenerTest = try NWListener(
            using: NWParameters(tls: nil),
            on: NWEndpoint.Port(rawValue: 0)!
        )
        let listener = try NIOTSListenerBootstrap(group: self.group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(EchoHandler())
                }
            }
            .withNWListener(nwListenerTest).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let nwConnectionTest = NWConnection(
            host: NWEndpoint.Host("localhost"),
            port: nwListenerTest.port!,
            using: NWParameters(tls: nil)
        )
        let connection = try NIOTSConnectionBootstrap(group: self.group)

            .withExistingNWConnection(nwConnectionTest).wait()
        defer {
            XCTAssertNoThrow(try connection.close().wait())
        }

        let buffer = connection.allocator.bufferFor(string: "hello, world!")
        let completeFuture = connection.expectRead(buffer)
        connection.writeAndFlush(buffer, promise: nil)
        //        this is the assert that matters to make sure it works & writes data
        XCTAssertNoThrow(try completeFuture.wait())
    }

    func testMultipleConnectionsOneListener() throws {
        let listener = try NIOTSListenerBootstrap(group: self.group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(EchoHandler())
                }
            }
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let bootstrap = NIOTSConnectionBootstrap(group: self.group)

        let completeFutures: [EventLoopFuture<Void>] = (0..<10).map { _ in
            bootstrap.connect(to: listener.localAddress!).flatMap { channel -> EventLoopFuture<Void> in
                let buffer = channel.allocator.bufferFor(string: "hello, world!")
                let completeFuture = channel.expectRead(buffer)
                channel.writeAndFlush(buffer, promise: nil)
                return completeFuture
            }
        }

        let allDoneFuture = EventLoopFuture<Void>.andAllComplete(completeFutures, on: self.group.next())
        XCTAssertNoThrow(try allDoneFuture.wait())
    }

    func testBasicConnectionTeardown() throws {
        let listener = try NIOTSListenerBootstrap(group: self.group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(CloseOnActiveHandler())
                }
            }
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let bootstrap = NIOTSConnectionBootstrap(group: self.group)

        let closeFutures: [EventLoopFuture<Void>] = (0..<10).map { _ in
            bootstrap.connect(to: listener.localAddress!).flatMap { channel in
                channel.closeFuture
            }
        }

        let allClosed = EventLoopFuture<Void>.andAllComplete(closeFutures, on: self.group.next())
        XCTAssertNoThrow(try allClosed.wait())
    }

    func testCloseFromClientSide() throws {
        // This test is a little bit dicey, but we need 20 futures in this list.
        let closeFutureSyncQueue = DispatchQueue(label: "closeFutureSyncQueue")
        let closeFutureGroup = DispatchGroup()
        let closeFutures: NIOLockedValueBox<[EventLoopFuture<Void>]> = .init([])

        let listener = try NIOTSListenerBootstrap(group: self.group)
            .childChannelInitializer { channel in
                closeFutureSyncQueue.sync {
                    closeFutures.withLockedValue { $0.append(channel.closeFuture) }
                }
                closeFutureGroup.leave()
                return channel.eventLoop.makeSucceededFuture(())
            }
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let bootstrap = NIOTSConnectionBootstrap(group: self.group).channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(CloseOnActiveHandler())
            }
        }

        for _ in (0..<10) {
            // Each connection attempt needs to enter the group twice: each end will leave it once
            // for us.
            closeFutureGroup.enter()
            closeFutureGroup.enter()
            bootstrap.connect(to: listener.localAddress!).whenSuccess { channel in
                closeFutureSyncQueue.sync {
                    closeFutures.withLockedValue { $0.append(channel.closeFuture) }
                }
                closeFutureGroup.leave()
            }
        }

        closeFutureGroup.wait()
        let allClosed = closeFutureSyncQueue.sync {
            closeFutures.withLockedValue {
                EventLoopFuture<Void>.andAllComplete($0, on: self.group.next())
            }
        }
        XCTAssertNoThrow(try allClosed.wait())
    }

    func testAgreeOnRemoteLocalAddresses() throws {
        let serverSideConnectionPromise: EventLoopPromise<Channel> = self.group.next().makePromise()
        let listener = try NIOTSListenerBootstrap(group: self.group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        WaitForActiveHandler(serverSideConnectionPromise),
                        EchoHandler(),
                    ])
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

        let serverSideConnection = try serverSideConnectionPromise.futureResult.wait()

        XCTAssertEqual(connection.remoteAddress, listener.localAddress)
        XCTAssertEqual(connection.remoteAddress, serverSideConnection.localAddress)
        XCTAssertEqual(connection.localAddress, serverSideConnection.remoteAddress)
    }

    func testHalfClosureSupported() throws {
        let halfClosedPromise: EventLoopPromise<Void> = self.group.next().makePromise()
        let listener = try NIOTSListenerBootstrap(group: self.group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(EchoHandler())
                    try channel.pipeline.syncOperations.addHandler(HalfCloseHandler(halfClosedPromise))
                }
            }
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let connection = try NIOTSConnectionBootstrap(group: self.group)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .connect(to: listener.localAddress!).wait()

        // First check the channel is working.
        let buffer = connection.allocator.bufferFor(string: "hello, world!")
        let completeFuture = connection.expectRead(buffer)
        connection.writeAndFlush(buffer, promise: nil)
        XCTAssertNoThrow(try completeFuture.wait())

        // Ok, now half-close. This should propagate to the remote peer, which should also
        // close its end, leading to complete shutdown of the connection.
        XCTAssertNoThrow(try connection.close(mode: .output).wait())
        XCTAssertNoThrow(try halfClosedPromise.futureResult.wait())
        XCTAssertNoThrow(try connection.closeFuture.wait())
    }

    func testDisabledHalfClosureCausesFullClosure() throws {
        let listener = try NIOTSListenerBootstrap(group: self.group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(EchoHandler())
                    try channel.pipeline.syncOperations.addHandler(FailOnHalfCloseHandler())
                }
            }
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let connection = try NIOTSConnectionBootstrap(group: self.group)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .connect(to: listener.localAddress!).wait()

        // First check the channel is working.
        let buffer = connection.allocator.bufferFor(string: "hello, world!")
        let completeFuture = connection.expectRead(buffer)
        connection.writeAndFlush(buffer, promise: nil)
        XCTAssertNoThrow(try completeFuture.wait())

        // Ok, now half-close. This should propagate to the remote peer, which should also
        // close its end, leading to complete shutdown of the connection.
        XCTAssertNoThrow(try connection.close(mode: .output).wait())
        XCTAssertNoThrow(try connection.closeFuture.wait())
    }

    func testHalfClosingTwiceFailsTheSecondTime() throws {
        let listener = try NIOTSListenerBootstrap(group: self.group)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let connection = try NIOTSConnectionBootstrap(group: self.group)
            .connect(to: listener.localAddress!).wait()

        // Ok, now half-close. First one should be fine.
        XCTAssertNoThrow(try connection.close(mode: .output).wait())

        // Second one won't be.
        do {
            try connection.close(mode: .output).wait()
            XCTFail("Did not throw")
        } catch ChannelError.outputClosed {
            // ok
        } catch {
            XCTFail("Threw unexpected error \(error)")
        }
    }

    func testHalfClosingInboundSideIsRejected() throws {
        let listener = try NIOTSListenerBootstrap(group: self.group)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let connection = try NIOTSConnectionBootstrap(group: self.group)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .connect(to: listener.localAddress!).wait()

        // Ok, now try to half-close the input.
        do {
            try connection.close(mode: .input).wait()
            XCTFail("Did not throw")
        } catch ChannelError.operationUnsupported {
            // ok
        } catch {
            XCTFail("Threw unexpected error \(error)")
        }
    }

    func testBasicUnixSockets() throws {
        // We don't use FileManager here because this code round-trips through sockaddr_un, and
        // sockaddr_un cannot hold paths as long as the true temporary directories used by
        // FileManager.
        let udsPath = "/tmp/\(UUID().uuidString)_testBasicUnixSockets.sock"

        let listener = try NIOTSListenerBootstrap(group: self.group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(EchoHandler())
                }
            }
            .bind(unixDomainSocketPath: udsPath).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let connection = try NIOTSConnectionBootstrap(group: self.group)
            .connect(unixDomainSocketPath: udsPath).wait()
        defer {
            XCTAssertNoThrow(try connection.close().wait())
        }

        XCTAssertEqual(listener.localAddress, connection.remoteAddress)
        XCTAssertNil(connection.localAddress)

        let buffer = connection.allocator.bufferFor(string: "hello, world!")
        let completeFuture = connection.expectRead(buffer)
        connection.writeAndFlush(buffer, promise: nil)
        XCTAssertNoThrow(try completeFuture.wait())
    }

    func testFancyEndpointSupport() throws {
        // This test validates that we can use NWEndpoints properly by doing something core NIO
        // cannot: setting up and connecting to a Bonjour service. To avoid the risk of multiple
        // users running this test on the same network at the same time and getting in each others
        // way we use a UUID to distinguish the service.
        let name = UUID().uuidString
        let serviceEndpoint = NWEndpoint.service(name: name, type: "_niots._tcp", domain: "local", interface: nil)

        let listener = try NIOTSListenerBootstrap(group: self.group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(EchoHandler())
                }
            }
            .bind(endpoint: serviceEndpoint).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let connection = try NIOTSConnectionBootstrap(group: self.group)
            .connectTimeout(.hours(1))
            .connect(endpoint: serviceEndpoint).wait()
        defer {
            XCTAssertNoThrow(try connection.close().wait())
        }

        XCTAssertNotNil(connection.localAddress)
        XCTAssertNotNil(connection.remoteAddress)
        XCTAssertNil(listener.localAddress)
        XCTAssertNil(listener.remoteAddress)

        let buffer = connection.allocator.bufferFor(string: "hello, world!")
        let completeFuture = connection.expectRead(buffer)
        connection.writeAndFlush(buffer, promise: nil)
        XCTAssertNoThrow(try completeFuture.wait())
    }

    func testBasicConnectionTimeout() throws {
        let listener = try NIOTSListenerBootstrap(group: self.group)
            .serverChannelOption(ChannelOptions.socket(SOL_SOCKET, SO_REUSEADDR), value: 0)
            .serverChannelOption(ChannelOptions.socket(SOL_SOCKET, SO_REUSEPORT), value: 0)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(CloseOnActiveHandler())
                }
            }
            .bind(host: "localhost", port: 0).wait()
        let address = listener.localAddress!

        // let's close the server socket, we disable SO_REUSEPORT/SO_REUSEADDR so that nobody can bind this for a
        // while.
        XCTAssertNoThrow(try listener.close().wait())

        // this should now definitely time out.
        XCTAssertThrowsError(
            try NIOTSConnectionBootstrap(group: self.group)
                .connectTimeout(.milliseconds(10))
                .connect(to: address)
                .wait()
        ) { error in
            print(error)
        }
    }

    func testViabilityUpdate() throws {
        final class ViabilityHandler: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer

            private let testCompletePromise: EventLoopPromise<Bool>

            init(testCompletePromise: EventLoopPromise<Bool>) {
                self.testCompletePromise = testCompletePromise
            }

            func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
                if let update = event as? NIOTSNetworkEvents.ViabilityUpdate {
                    testCompletePromise.succeed(update.isViable)
                }
            }
        }

        let listener = try NIOTSListenerBootstrap(group: self.group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeSucceededVoidFuture()
            }
            .bind(host: "localhost", port: 0)
            .wait()

        let testCompletePromise = self.group.next().makePromise(of: Bool.self)
        let connection = try NIOTSConnectionBootstrap(group: self.group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        ViabilityHandler(testCompletePromise: testCompletePromise)
                    )
                }
            }
            .connect(to: listener.localAddress!)
            .wait()

        do {
            let result = try testCompletePromise.futureResult.wait()
            XCTAssertEqual(result, true)
        } catch {
            XCTFail("Threw unexpected error \(error)")
        }
        XCTAssertNoThrow(try connection.close().wait())
        XCTAssertNoThrow(try listener.close().wait())
    }
}
#endif
