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

//===----------------------------------------------------------------------===//
// This test isolates a NIOTS UDP client talking to a POSIX UDP echo server.
// It sends two datagrams: "hello" and "world". Both echoes are asserted
// strictly.
//===----------------------------------------------------------------------===//

//    How to run just this test
//
//    - From the swift-nio-transport-services repo root:
//    - swift test -v --filter NIOTransportServicesTests/NIOTSUDPMultiDatagramsPOSIXServerTests.testNIOTSClient_POSIXServer_MultipleDatagrams

#if canImport(Network)
import XCTest
import NIOCore
import NIOPosix
import NIOTransportServices

private final class POSIXUDPEchoHandler: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = self.unwrapInboundIn(data)
        context.write(self.wrapOutboundOut(envelope), promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Keep the server simple; close on error
        context.close(promise: nil)
    }
}

private final class ClientCaptureHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let onRead: (String) -> Void
    init(onRead: @escaping (String) -> Void) { self.onRead = onRead }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = self.unwrapInboundIn(data)
        let s = buf.readString(length: buf.readableBytes) ?? ""
        // print("[client] read:", s)
        self.onRead(s)
    }
}

private final class UDPClientActiveHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    private let activePromise: EventLoopPromise<Void>
    init(_ p: EventLoopPromise<Void>) { self.activePromise = p }
    func channelActive(context: ChannelHandlerContext) {
        self.activePromise.succeed(())
        context.fireChannelActive()
    }
}

final class NIOTSUDPMultiDatagramsPOSIXServerTests: XCTestCase {
    func testNIOTSClient_POSIXServer_MultipleDatagrams() throws {
        // POSIX UDP echo server
        let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try serverGroup.syncShutdownGracefully()) }

        let server = try DatagramBootstrap(group: serverGroup)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandler(POSIXUDPEchoHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        defer { XCTAssertNoThrow(try server.close().wait()) }

        guard let port = server.localAddress?.port else {
            XCTFail("No server port")
            return
        }

        // NIOTS connected UDP client
        let clientGroup = NIOTSEventLoopGroup(loopCount: 1)
        defer { XCTAssertNoThrow(try clientGroup.syncShutdownGracefully()) }

        let gotHello = expectation(description: "got hello")
        let gotWorld = expectation(description: "got world")

        let clientActive = clientGroup.next().makePromise(of: Void.self)
        let client = try NIOTSDatagramConnectionBootstrap(group: clientGroup)
            .channelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandler(UDPClientActiveHandler(clientActive))
                    try ch.pipeline.syncOperations.addHandler(
                        ClientCaptureHandler { text in
                            if text == "hello" { gotHello.fulfill() }
                            if text == "world" { gotWorld.fulfill() }
                        }
                    )
                }
            }
            .connect(host: "127.0.0.1", port: port)
            .wait()

        defer { XCTAssertNoThrow(try client.close().wait()) }

        // Avoid early write before active
        XCTAssertNoThrow(try clientActive.futureResult.wait())

        // First datagram: expect echo strictly
        var hello = client.allocator.buffer(capacity: 5)
        hello.writeString("hello")
        XCTAssertNoThrow(try client.writeAndFlush(hello).wait())
        wait(for: [gotHello], timeout: 1.0)

        // Second datagram
        var world = client.allocator.buffer(capacity: 5)
        world.writeString("world")
        XCTAssertNoThrow(try client.writeAndFlush(world).wait())
        wait(for: [gotWorld], timeout: 1.0)
    }
}
#endif
