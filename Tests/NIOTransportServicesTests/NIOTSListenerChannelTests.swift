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


final class BindRecordingHandler: ChannelOutboundHandler {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    var bindTargets: [SocketAddress] = []
    var endpointTargets: [NWEndpoint] = []

    func bind(ctx: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        self.bindTargets.append(address)
        ctx.bind(to: address, promise: promise)
    }

    func triggerUserOutboundEvent(ctx: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        switch event {
        case let evt as NIOTSNetworkEvents.BindToNWEndpoint:
            self.endpointTargets.append(evt.endpoint)
        default:
            break
        }
        ctx.triggerUserOutboundEvent(event, promise: promise)
    }
}


class NIOTSListenerChannelTests: XCTestCase {
    private var group: NIOTSEventLoopGroup!

    override func setUp() {
        self.group = NIOTSEventLoopGroup(loopCount: 1)
    }

    override func tearDown() {
        XCTAssertNoThrow(try self.group.syncShutdownGracefully())
    }

    func testBindingToSocketAddressTraversesPipeline() throws {
        let bindRecordingHandler = BindRecordingHandler()
        let target = try SocketAddress.newAddressResolving(host: "localhost", port: 0)
        let bindBootstrap = NIOTSListenerBootstrap(group: self.group)
            .serverChannelInitializer { channel in channel.pipeline.add(handler: bindRecordingHandler)}

        XCTAssertEqual(bindRecordingHandler.bindTargets, [])
        XCTAssertEqual(bindRecordingHandler.endpointTargets, [])

        let listener = try bindBootstrap.bind(to: target).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        try self.group.next().submit {
            XCTAssertEqual(bindRecordingHandler.bindTargets, [target])
            XCTAssertEqual(bindRecordingHandler.endpointTargets, [])
        }.wait()
    }

    func testConnectingToHostPortTraversesPipeline() throws {
        let bindRecordingHandler = BindRecordingHandler()
        let bindBootstrap = NIOTSListenerBootstrap(group: self.group)
            .serverChannelInitializer { channel in channel.pipeline.add(handler: bindRecordingHandler)}

        XCTAssertEqual(bindRecordingHandler.bindTargets, [])
        XCTAssertEqual(bindRecordingHandler.endpointTargets, [])

        let listener = try bindBootstrap.bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        try self.group.next().submit {
            XCTAssertEqual(bindRecordingHandler.bindTargets, [try SocketAddress.newAddressResolving(host: "localhost", port: 0)])
            XCTAssertEqual(bindRecordingHandler.endpointTargets, [])
        }.wait()
    }

    func testConnectingToEndpointSkipsPipeline() throws {
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let bindRecordingHandler = BindRecordingHandler()
        let bindBootstrap = NIOTSListenerBootstrap(group: self.group)
            .serverChannelInitializer { channel in channel.pipeline.add(handler: bindRecordingHandler)}

        XCTAssertEqual(bindRecordingHandler.bindTargets, [])
        XCTAssertEqual(bindRecordingHandler.endpointTargets, [])

        let listener = try bindBootstrap.bind(endpoint: endpoint).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        try self.group.next().submit {
            XCTAssertEqual(bindRecordingHandler.bindTargets, [])
            XCTAssertEqual(bindRecordingHandler.endpointTargets, [endpoint])
        }.wait()
    }
}
