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

    func testSettingGettingReuseaddr() throws {
        let listener = try NIOTSListenerBootstrap(group: self.group).bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        XCTAssertEqual(0, try listener.getOption(option: ChannelOptions.socket(SOL_SOCKET, SO_REUSEADDR)).wait())
        XCTAssertNoThrow(try listener.setOption(option: ChannelOptions.socket(SOL_SOCKET, SO_REUSEADDR), value: 5).wait())
        XCTAssertEqual(1, try listener.getOption(option: ChannelOptions.socket(SOL_SOCKET, SO_REUSEADDR)).wait())
        XCTAssertNoThrow(try listener.setOption(option: ChannelOptions.socket(SOL_SOCKET, SO_REUSEADDR), value: 0).wait())
        XCTAssertEqual(0, try listener.getOption(option: ChannelOptions.socket(SOL_SOCKET, SO_REUSEADDR)).wait())
    }

    func testSettingGettingReuseport() throws {
        let listener = try NIOTSListenerBootstrap(group: self.group).bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        XCTAssertEqual(0, try listener.getOption(option: ChannelOptions.socket(SOL_SOCKET, SO_REUSEPORT)).wait())
        XCTAssertNoThrow(try listener.setOption(option: ChannelOptions.socket(SOL_SOCKET, SO_REUSEPORT), value: 5).wait())
        XCTAssertEqual(1, try listener.getOption(option: ChannelOptions.socket(SOL_SOCKET, SO_REUSEPORT)).wait())
        XCTAssertNoThrow(try listener.setOption(option: ChannelOptions.socket(SOL_SOCKET, SO_REUSEPORT), value: 0).wait())
        XCTAssertEqual(0, try listener.getOption(option: ChannelOptions.socket(SOL_SOCKET, SO_REUSEPORT)).wait())
    }

    func testErrorsInChannelSetupAreFine() throws {
        struct MyError: Error { }

        let listenerFuture = NIOTSListenerBootstrap(group: self.group)
            .serverChannelInitializer { channel in channel.eventLoop.newFailedFuture(error: MyError()) }
            .bind(host: "localhost", port: 0)

        do {
            let listener = try listenerFuture.wait()
            XCTAssertNoThrow(try listener.close().wait())
            XCTFail("Did not throw")
        } catch is MyError {
            // fine
        } catch {
            XCTFail("Unexpected error")
        }
    }

    func testCanSafelyInvokeChannelsAcrossThreads() throws {
        // This is a test that aims to trigger TSAN violations.
        let childGroup = NIOTSEventLoopGroup(loopCount: 2)
        let childChannelPromise: EventLoopPromise<Channel> = childGroup.next().newPromise()
        let activePromise: EventLoopPromise<Void> = childGroup.next().newPromise()

        let listener = try NIOTSListenerBootstrap(group: self.group, childGroup: childGroup)
            .childChannelInitializer { channel in
                childChannelPromise.succeed(result: channel)
                return channel.pipeline.add(handler: PromiseOnActiveHandler(activePromise))
            }.bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }

        // Connect to the listener.
        let channel = try NIOTSConnectionBootstrap(group: self.group)
            .connect(to: listener.localAddress!).wait()

        // Wait for the child channel to become active.
        let childChannel = try childChannelPromise.futureResult.wait()
        XCTAssertNoThrow(try activePromise.futureResult.wait())

        // Now close the child channel.
        XCTAssertNoThrow(try childChannel.close().wait())
        XCTAssertNoThrow(try channel.closeFuture.wait())
    }

    func testCanObserveValueOfEnablePeerToPeer() throws {
        let listener = try NIOTSListenerBootstrap(group: self.group)
            .serverChannelInitializer { channel in
                return channel.getOption(option: NIOTSChannelOptions.enablePeerToPeer).map { value in
                    XCTAssertFalse(value)
                }.then {
                    channel.setOption(option: NIOTSChannelOptions.enablePeerToPeer, value: true)
                }.then {
                    channel.getOption(option: NIOTSChannelOptions.enablePeerToPeer)
                }.map { value in
                    XCTAssertTrue(value)
                }
            }
            .bind(host: "localhost", port: 0).wait()
        defer {
            XCTAssertNoThrow(try listener.close().wait())
        }
    }
}
