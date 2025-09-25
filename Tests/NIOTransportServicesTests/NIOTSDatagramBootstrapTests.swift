//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2023 Apple Inc. and the SwiftNIO project authors
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
import NIOTransportServices
import Foundation
import NIOConcurrencyHelpers

extension Channel {
    func wait<T: Sendable>(for type: T.Type, count: Int) throws -> [T] {
        try self.pipeline.context(name: "ByteReadRecorder").flatMap { context in
            if let future = (context.handler as? ReadRecorder<T>)?.notifyForDatagrams(count) {
                return future
            }

            XCTFail("Could not wait for reads")
            return self.eventLoop.makeSucceededFuture([] as [T])
        }.wait()
    }

    func waitForDatagrams(count: Int) throws -> [ByteBuffer] {
        try wait(for: ByteBuffer.self, count: count)
    }

    func readCompleteCount() throws -> Int {
        try self.pipeline.context(name: "ByteReadRecorder").map { context in
            (context.handler as! ReadRecorder<ByteBuffer>).readCompleteCount
        }.wait()
    }

    func configureForRecvMmsg(messageCount: Int) throws {
        let totalBufferSize = messageCount * 2048

        try self.setOption(
            ChannelOptions.recvAllocator,
            value: FixedSizeRecvByteBufferAllocator(capacity: totalBufferSize)
        ).flatMap {
            self.setOption(ChannelOptions.datagramVectorReadMessageCount, value: messageCount)
        }.wait()
    }
}

private final class EchoByteBufferHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = self.unwrapInboundIn(data)
        context.writeAndFlush(self.wrapOutboundOut(buf), promise: nil)
        // Forward inbound so downstream handlers (e.g. ReadRecorder) can observe it.
        context.fireChannelRead(self.wrapInboundOut(buf))
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.fireChannelReadComplete()
    }
}

private func timedWaitForDatagrams(
    _ channel: Channel,
    count: Int,
    timeout: TimeAmount
) throws -> [ByteBuffer] {
    let loop = channel.eventLoop
    let result = loop.makePromise(of: [ByteBuffer].self)

    let want: EventLoopFuture<[ByteBuffer]> = channel.pipeline
        .context(name: "ByteReadRecorder")
        .flatMap { ctx in
            if let rec = ctx.handler as? ReadRecorder<ByteBuffer> {
                return rec.notifyForDatagrams(count)
            }
            return loop.makeSucceededFuture([])
        }

    let timeoutTask = loop.scheduleTask(in: timeout) {
        result.succeed([])  // empty => timed out (prevents indefinite stall)
    }
    want.whenComplete { res in
        timeoutTask.cancel()
        switch res {
        case .success(let reads): result.succeed(reads)
        case .failure(let error): result.fail(error)
        }
    }

    return try result.futureResult.wait()
}

final class ReadRecorder<DataType: Sendable>: ChannelInboundHandler {
    typealias InboundIn = DataType
    typealias InboundOut = DataType

    enum State {
        case fresh
        case registered
        case active
    }

    var reads: [DataType] = []
    var loop: EventLoop? = nil
    var state: State = .fresh

    var readWaiters: [Int: EventLoopPromise<[DataType]>] = [:]
    var readCompleteCount = 0

    func handlerAdded(context: ChannelHandlerContext) {
        self.loop = context.eventLoop
    }

    func channelRegistered(context: ChannelHandlerContext) {
        XCTAssertEqual(.fresh, self.state)
        self.state = .registered
    }

    func channelActive(context: ChannelHandlerContext) {
        XCTAssertEqual(.registered, self.state)
        self.state = .active
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        XCTAssertEqual(.active, self.state)
        let data = self.unwrapInboundIn(data)
        reads.append(data)

        if let promise = readWaiters.removeValue(forKey: reads.count) {
            promise.succeed(reads)
        }

        context.fireChannelRead(self.wrapInboundOut(data))
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        self.readCompleteCount += 1
        context.fireChannelReadComplete()
    }

    func notifyForDatagrams(_ count: Int) -> EventLoopFuture<[DataType]> {
        guard reads.count < count else {
            return loop!.makeSucceededFuture(.init(reads.prefix(count)))
        }

        readWaiters[count] = loop!.makePromise()
        return readWaiters[count]!.futureResult
    }
}

// Mimicks the DatagramChannelTest from apple/swift-nio
@available(macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 6, *)
final class NIOTSDatagramBootstrapTests: XCTestCase {
    private var group: NIOTSEventLoopGroup!

    private func buildServerChannel(
        group: NIOTSEventLoopGroup,
        host: String = "127.0.0.1",
        port: Int = 0,
        onConnect: @escaping @Sendable (Channel) -> Void
    ) throws -> Channel {
        try NIOTSDatagramListenerBootstrap(group: group)
            .childChannelInitializer { childChannel in
                onConnect(childChannel)
                return childChannel.eventLoop.makeCompletedFuture {
                    try childChannel.pipeline.syncOperations.addHandler(
                        ReadRecorder<ByteBuffer>(),
                        name: "ByteReadRecorder"
                    )
                }
            }
            .bind(host: host, port: port)
            .wait()
    }

    private func buildClientChannel(
        group: NIOTSEventLoopGroup,
        host: String = "127.0.0.1",
        port: Int
    ) throws -> Channel {
        try NIOTSDatagramConnectionBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        ReadRecorder<ByteBuffer>(),
                        name: "ByteReadRecorder"
                    )
                }
            }
            .connect(host: host, port: port)
            .wait()
    }

    override func setUp() {
        super.setUp()
        self.group = NIOTSEventLoopGroup()
        self.continueAfterFailure = false
    }

    override func tearDown() {
        XCTAssertNoThrow(try self.group.syncShutdownGracefully())
    }

    func testBasicChannelCommunication() throws {
        let serverHandlePromise = group.next().makePromise(of: Channel.self)
        let server = try buildServerChannel(group: group, onConnect: serverHandlePromise.succeed)
        let client = try buildClientChannel(group: group, port: server.localAddress!.port!)

        var buffer = client.allocator.buffer(capacity: 256)
        buffer.writeStaticString("hello, world!")
        XCTAssertNoThrow(try client.writeAndFlush(buffer).wait())

        let serverHandle = try serverHandlePromise.futureResult.wait()

        let reads = try serverHandle.waitForDatagrams(count: 1)

        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(reads[0], buffer)
    }

    func testConnectedUDPEchoesTwoDatagrams() throws {
        // Server: NIOTS datagram listener with an echoing child channel.
        let serverHandlePromise = self.group.next().makePromise(of: Channel.self)
        let server = try self.buildServerChannel(
            group: self.group,
            onConnect: { child in
                // Install echo before the recorder to bounce datagrams back to the client.
                try! child.pipeline.syncOperations.addHandler(EchoByteBufferHandler())
                serverHandlePromise.succeed(child)
            }
        )
        defer { XCTAssertNoThrow(try server.close().wait()) }

        // Client: NIOTS connected UDP with ByteReadRecorder (added in buildClientChannel).
        let client = try self.buildClientChannel(group: self.group, port: server.localAddress!.port!)
        defer { XCTAssertNoThrow(try client.close().wait()) }

        // Send “hello”, expect the first echo strictly.
        var hello = client.allocator.buffer(capacity: 50)
        hello.writeString("hello")
        XCTAssertNoThrow(try client.writeAndFlush(hello).wait())

        // Obtain the server-side child channel created upon first datagram arrival
        // and assert the server observed the datagram as well.
        let serverHandle = try serverHandlePromise.futureResult.wait()
        do {
            let serverReads = try serverHandle.waitForDatagrams(count: 1)
            XCTAssertEqual(serverReads.count, 1)
            XCTAssertEqual(serverReads[0], hello)
        } catch {
            XCTFail("Server did not observe first datagram: \(error)")
        }

        do {
            let reads = try timedWaitForDatagrams(client, count: 1, timeout: .seconds(1))
            XCTAssertEqual(reads.count, 1)
            XCTAssertEqual(reads[0], hello)
        } catch {
            XCTFail("Did not receive first echo: \(error)")
        }

        // Send “world” and expect a second echo as well (strict).
        var world = client.allocator.buffer(capacity: 5)
        world.writeString("world")
        XCTAssertNoThrow(try client.writeAndFlush(world).wait())

        // Server should observe the second datagram too.
        do {
            let serverReads = try serverHandle.waitForDatagrams(count: 2)
            XCTAssertEqual(serverReads.count, 2)
            XCTAssertEqual(serverReads[1], world)
        } catch {
            XCTFail("Server did not observe second datagram: \(error)")
        }

        do {
            let reads = try timedWaitForDatagrams(client, count: 2, timeout: .seconds(2))
            XCTAssertEqual(reads.count, 2)
            XCTAssertEqual(reads[1], world)
        } catch {
            XCTFail("Did not receive second echo: \(error)")
        }
    }

    func testSyncOptionsAreSupported() throws {
        @Sendable func testSyncOptions(_ channel: Channel) {
            if let sync = channel.syncOptions {
                do {
                    let endpointReuse = try sync.getOption(NIOTSChannelOptions.allowLocalEndpointReuse)
                    try sync.setOption(NIOTSChannelOptions.allowLocalEndpointReuse, value: !endpointReuse)
                    XCTAssertNotEqual(endpointReuse, try sync.getOption(NIOTSChannelOptions.allowLocalEndpointReuse))
                } catch {
                    XCTFail("Could not get/set allowLocalEndpointReuse: \(error)")
                }
            } else {
                XCTFail("\(channel) unexpectedly returned nil syncOptions")
            }
        }

        let promise = self.group.any().makePromise(of: Channel.self)
        let listener = try NIOTSDatagramListenerBootstrap(group: self.group)
            .serverChannelInitializer { channel in
                testSyncOptions(channel)
                return channel.eventLoop.makeSucceededVoidFuture()
            }
            .childChannelInitializer { channel in
                testSyncOptions(channel)
                promise.succeed(channel)
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        ReadRecorder<ByteBuffer>(),
                        name: "ByteReadRecorder"
                    )
                }
            }
            .bind(host: "localhost", port: 0)
            .wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let connection = try! NIOTSDatagramConnectionBootstrap(group: self.group)
            .channelInitializer { channel in
                testSyncOptions(channel)
                return channel.eventLoop.makeSucceededVoidFuture()
            }
            .connect(to: listener.localAddress!)
            .wait()
        try connection.writeAndFlush(ByteBuffer(string: "hello world")).wait()

        let serverHandle = try promise.futureResult.wait()
        _ = try serverHandle.waitForDatagrams(count: 1)
        XCTAssertNoThrow(try connection.close().wait())
    }

    func testNWParametersConfigurator() async throws {
        try await withEventLoopGroup { group in
            let configuratorServerListenerCounter = NIOLockedValueBox(0)
            let configuratorServerConnectionCounter = NIOLockedValueBox(0)
            let configuratorClientConnectionCounter = NIOLockedValueBox(0)
            let waitForConnectionHandler = WaitForConnectionHandler(
                connectionPromise: group.next().makePromise()
            )

            let listenerChannel = try await NIOTSDatagramListenerBootstrap(group: group)
                .childChannelInitializer { connectionChannel in
                    connectionChannel.eventLoop.makeCompletedFuture {
                        try connectionChannel.pipeline.syncOperations.addHandler(waitForConnectionHandler)
                    }
                }
                .configureNWParameters { _ in
                    configuratorServerListenerCounter.withLockedValue { $0 += 1 }
                }
                .configureChildNWParameters { _ in
                    configuratorServerConnectionCounter.withLockedValue { $0 += 1 }
                }
                .bind(host: "localhost", port: 0)
                .get()

            let connectionChannel: Channel = try await NIOTSDatagramConnectionBootstrap(group: group)
                .configureNWParameters { _ in
                    configuratorClientConnectionCounter.withLockedValue { $0 += 1 }
                }
                .connect(to: listenerChannel.localAddress!)
                .get()

            // Need to write something so the server can activate the connection channel: this is UDP,
            // so there is no handshaking that happens and thus the server cannot know that the
            // connection has been established and the channel can be activated until we receive something.
            try await connectionChannel.writeAndFlush(ByteBuffer(bytes: [42]))

            // Wait for the server to activate the connection channel to the client.
            try await waitForConnectionHandler.connectionPromise.futureResult.get()

            try await listenerChannel.close().get()
            try await connectionChannel.close().get()

            XCTAssertEqual(1, configuratorServerListenerCounter.withLockedValue { $0 })
            XCTAssertEqual(1, configuratorServerConnectionCounter.withLockedValue { $0 })
            XCTAssertEqual(1, configuratorClientConnectionCounter.withLockedValue { $0 })
        }
    }

    func testCanExtractTheConnection() throws {
        guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) else {
            throw XCTSkip("Option not available")
        }

        let listener = try NIOTSDatagramListenerBootstrap(group: self.group)
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        _ = try NIOTSDatagramConnectionBootstrap(group: self.group)
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

    func testCanExtractTheListener() throws {
        guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) else {
            throw XCTSkip("Option not available")
        }

        let listener = try NIOTSDatagramListenerBootstrap(group: self.group)
            .serverChannelInitializer { channel in
                let underlyingListener = try! channel.syncOptions!.getOption(NIOTSChannelOptions.listener)
                XCTAssertNil(underlyingListener)
                return channel.eventLoop.makeSucceededVoidFuture()
            }
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        let listenerFuture: EventLoopFuture<NWListener?> = listener.getOption(NIOTSChannelOptions.listener)

        try listenerFuture.map { listener in
            XCTAssertNotNil(listener)
        }.wait()
    }
}
#endif
