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

extension Channel {
    func wait<T>(for type: T.Type, count: Int) throws -> [T] {
        return try self.pipeline.context(name: "ByteReadRecorder").flatMap { context in
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
        return try self.pipeline.context(name: "ByteReadRecorder").map { context in
            return (context.handler as! ReadRecorder<ByteBuffer>).readCompleteCount
        }.wait()
    }

    func configureForRecvMmsg(messageCount: Int) throws {
        let totalBufferSize = messageCount * 2048

        try self.setOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: totalBufferSize)).flatMap {
            self.setOption(ChannelOptions.datagramVectorReadMessageCount, value: messageCount)
        }.wait()
    }
}

final class ReadRecorder<DataType>: ChannelInboundHandler {
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
final class NIOTSDatagramConnectionChannelTests: XCTestCase {
    private var group: NIOTSEventLoopGroup!

    private func buildServerChannel(group: NIOTSEventLoopGroup, host: String = "127.0.0.1", port: Int = 0, onConnect: @escaping (Channel) -> ()) throws -> Channel {
        return try NIOTSDatagramListenerBootstrap(group: group)
            .childChannelInitializer { childChannel in
                onConnect(childChannel)
                return childChannel.pipeline.addHandler(ReadRecorder<ByteBuffer>(), name: "ByteReadRecorder")
            }
            .bind(host: host, port: port)
            .wait()
    }

    private func buildClientChannel(group: NIOTSEventLoopGroup, host: String = "127.0.0.1", port: Int) throws -> Channel {
        return try NIOTSDatagramBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(ReadRecorder<ByteBuffer>(), name: "ByteReadRecorder")
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
}
#endif
