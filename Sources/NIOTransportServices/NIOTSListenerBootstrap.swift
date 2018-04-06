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
import NIO
import Dispatch
import Network


public final class NIOTSListenerBootstrap {
    private let group: EventLoopGroup
    private let childGroup: EventLoopGroup
    private var serverChannelInit: ((Channel) -> EventLoopFuture<Void>)?
    private var childChannelInit: ((Channel) -> EventLoopFuture<Void>)?
    private var serverChannelOptions = ChannelOptionStorage()
    private var childChannelOptions = ChannelOptionStorage()
    private var serverQoS: DispatchQoS?
    private var childQoS: DispatchQoS?
    private var tcpOptions: NWProtocolTCP.Options = .init()
    private var tlsOptions: NWProtocolTLS.Options?

    /// Create a `NIOTSListenerBootstrap` for the `EventLoopGroup` `group`.
    ///
    /// - parameters:
    ///     - group: The `EventLoopGroup` to use for the `ServerSocketChannel`.
    public convenience init(group: NIOTSEventLoopGroup) {
        self.init(group: group, childGroup: group)
    }

    /// Create a `NIOTSListenerBootstrap`.
    ///
    /// - parameters:
    ///     - group: The `NIOTSEventLoopGroup` to use for the `bind` of the `NIOTSListenerChannel`
    ///         and to accept new `NIOTSConnectionChannel`s with.
    ///     - childGroup: The `NIOTSEventLoopGroup` to run the accepted `NIOTSConnectionChannel`s on.
    public init(group: NIOTSEventLoopGroup, childGroup: NIOTSEventLoopGroup) {
        self.group = group
        self.childGroup = childGroup
    }

    /// Initialize the `NIOTSListenerChannel` with `initializer`. The most common task in initializer is to add
    /// `ChannelHandler`s to the `ChannelPipeline`.
    ///
    /// The `NIOTSListenerChannel` uses the accepted `NIOTSConnectionChannel`s as inbound messages.
    ///
    /// - note: To set the initializer for the accepted `NIOTSConnectionChannel`s, look at
    ///     `ServerBootstrap.childChannelInitializer`.
    ///
    /// - parameters:
    ///     - initializer: A closure that initializes the provided `Channel`.
    public func serverChannelInitializer(_ initializer: @escaping (Channel) -> EventLoopFuture<Void>) -> Self {
        self.serverChannelInit = initializer
        return self
    }

    /// Initialize the accepted `NIOTSConnectionChannel`s with `initializer`. The most common task in initializer is to add
    /// `ChannelHandler`s to the `ChannelPipeline`.
    ///
    /// The accepted `Channel` will operate on `ByteBuffer` as inbound and `IOData` as outbound messages.
    ///
    /// - parameters:
    ///     - initializer: A closure that initializes the provided `Channel`.
    public func childChannelInitializer(_ initializer: @escaping (Channel) -> EventLoopFuture<Void>) -> Self {
        self.childChannelInit = initializer
        return self
    }

    /// Specifies a `ChannelOption` to be applied to the `NIOTSListenerChannel`.
    ///
    /// - note: To specify options for the accepted `NIOTSConnectionChannels`s, look at `NIOTSListenerBootstrap.childChannelOption`.
    ///
    /// - parameters:
    ///     - option: The option to be applied.
    ///     - value: The value for the option.
    public func serverChannelOption<T: ChannelOption>(_ option: T, value: T.OptionType) -> Self {
        self.serverChannelOptions.put(key: option, value: value)
        return self
    }

    /// Specifies a `ChannelOption` to be applied to the accepted `NIOTSConnectionChannel`s.
    ///
    /// - parameters:
    ///     - option: The option to be applied.
    ///     - value: The value for the option.
    public func childChannelOption<T: ChannelOption>(_ option: T, value: T.OptionType) -> Self {
        self.childChannelOptions.put(key: option, value: value)
        return self
    }


    /// Specifies a QoS to use for the server channel, instead of the default QoS for the
    /// event loop.
    ///
    /// This allows unusually high or low priority workloads to be appropriately scheduled.
    public func serverQoS(_ qos: DispatchQoS) -> Self {
        self.serverQoS = qos
        return self
    }


    /// Specifies a QoS to use for the child connections created from the server channel,
    /// instead of the default QoS for the event loop.
    ///
    /// This allows unusually high or low priority workloads to be appropriately scheduled.
    public func childQoS(_ qos: DispatchQoS) -> Self {
        self.childQoS = qos
        return self
    }

    /// Specifies the TCP options to use on the child `Channel`s.
    ///
    /// To retrieve the TCP options from connected channels, use
    /// `NIOTSChannelOptions.TCPConfiguration`. It is not possible to change the
    /// TCP configuration after `bind` is called.
    public func tcpOptions(_ options: NWProtocolTCP.Options) -> Self {
        self.tcpOptions = options
        return self
    }

    /// Specifies the TLS options to use on the child `Channel`s.
    ///
    /// To retrieve the TLS options from connected channels, use
    /// `NIOTSChannelOptions.TLSConfiguration`. It is not possible to change the
    /// TLS configuration after `bind` is called.
    public func tlsOptions(_ options: NWProtocolTLS.Options) -> Self {
        self.tlsOptions = options
        return self
    }

    /// Bind the `NIOTSListenerChannel` to `host` and `port`.
    ///
    /// - parameters:
    ///     - host: The host to bind on.
    ///     - port: The port to bind on.
    public func bind(host: String, port: Int) -> EventLoopFuture<Channel> {
        return self.bind0 { channel in
            let p: EventLoopPromise<Void> = channel.eventLoop.newPromise()
            do {
                // NWListener does not actually resolve hostname-based NWEndpoints
                // for use with requiredLocalEndpoint, so we fall back to
                // SocketAddress for this.
                let address = try SocketAddress.newAddressResolving(host: host, port: port)
                channel.bind(to: address, promise: p)
            } catch {
                p.fail(error: error)
            }
            return p.futureResult
        }
    }

    /// Bind the `NIOTSListenerChannel` to `address`.
    ///
    /// - parameters:
    ///     - address: The `SocketAddress` to bind on.
    public func bind(to address: SocketAddress) -> EventLoopFuture<Channel> {
        return self.bind0 { channel in
            channel.bind(to: address)
        }
    }

    /// Bind the `NIOTSListenerChannel` to a UNIX Domain Socket.
    ///
    /// - parameters:
    ///     - unixDomainSocketPath: The _Unix domain socket_ path to bind to. `unixDomainSocketPath` must not exist, it will be created by the system.
    public func bind(unixDomainSocketPath: String) -> EventLoopFuture<Channel> {
        return self.bind0 { channel in
            let p: EventLoopPromise<Void> = channel.eventLoop.newPromise()
            do {
                let address = try SocketAddress(unixDomainSocketPath: unixDomainSocketPath)
                channel.bind(to: address, promise: p)
            } catch {
                p.fail(error: error)
            }
            return p.futureResult
        }
    }

    /// Bind the `NIOTSListenerChannel` to a given `NWEndpoint`.
    ///
    /// - parameters:
    ///     - endpoint: The `NWEndpoint` to bind this channel to.
    public func bind(endpoint: NWEndpoint) -> EventLoopFuture<Channel> {
        return self.bind0 { channel in
            channel.triggerUserOutboundEvent(NIOTSNetworkEvents.BindToNWEndpoint(endpoint: endpoint))
        }
    }

    private func bind0(_ binder: @escaping (Channel) -> EventLoopFuture<Void>) -> EventLoopFuture<Channel> {
        let eventLoop = self.group.next() as! NIOTSEventLoop
        let childEventLoopGroup = self.childGroup as! NIOTSEventLoopGroup
        let serverChannelInit = self.serverChannelInit ?? { _ in eventLoop.newSucceededFuture(result: ()) }
        let childChannelInit = self.childChannelInit
        let serverChannelOptions = self.serverChannelOptions
        let childChannelOptions = self.childChannelOptions

        let serverChannel = NIOTSListenerChannel(eventLoop: eventLoop,
                                                 qos: self.serverQoS,
                                                 tcpOptions: self.tcpOptions,
                                                 tlsOptions: self.tlsOptions)

        return eventLoop.submit {
            return serverChannelOptions.applyAll(channel: serverChannel).then {
                serverChannelInit(serverChannel)
            }.then {
                serverChannel.pipeline.add(handler: AcceptHandler(childChannelInitializer: childChannelInit,
                                                                  childGroup: childEventLoopGroup,
                                                                  childChannelOptions: childChannelOptions,
                                                                  childChannelQoS: self.childQoS,
                                                                  tcpOptions: self.tcpOptions,
                                                                  tlsOptions: self.tlsOptions))
            }.then {
                serverChannel.register()
            }.then {
                binder(serverChannel)
            }.map {
                serverChannel as Channel
            }.thenIfError { error in
                serverChannel.close0(error: error, mode: .all, promise: nil)
                return eventLoop.newFailedFuture(error: error)
            }
        }.then {
            $0
        }
    }
}


private class AcceptHandler: ChannelInboundHandler {
    typealias InboundIn = NWConnection
    typealias InboundOut = NIOTSConnectionChannel

    private let childChannelInitializer: ((Channel) -> EventLoopFuture<Void>)?
    private let childGroup: NIOTSEventLoopGroup
    private let childChannelOptions: ChannelOptionStorage
    private let childChannelQoS: DispatchQoS?
    private let originalTCPOptions: NWProtocolTCP.Options
    private let originalTLSOptions: NWProtocolTLS.Options?

    init(childChannelInitializer: ((Channel) -> EventLoopFuture<Void>)?,
         childGroup: NIOTSEventLoopGroup,
         childChannelOptions: ChannelOptionStorage,
         childChannelQoS: DispatchQoS?,
         tcpOptions: NWProtocolTCP.Options,
         tlsOptions: NWProtocolTLS.Options?) {
        self.childChannelInitializer = childChannelInitializer
        self.childGroup = childGroup
        self.childChannelOptions = childChannelOptions
        self.childChannelQoS = childChannelQoS
        self.originalTCPOptions = tcpOptions
        self.originalTLSOptions = tlsOptions
    }

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let conn = self.unwrapInboundIn(data)
        let childLoop = self.childGroup.next() as! NIOTSEventLoop
        let ctxEventLoop = ctx.eventLoop
        let childInitializer = self.childChannelInitializer ?? { _ in childLoop.newSucceededFuture(result: ()) }
        let newChannel = NIOTSConnectionChannel(wrapping: conn,
                                                on: childLoop,
                                                parent: ctx.channel,
                                                qos: self.childChannelQoS,
                                                tcpOptions: self.originalTCPOptions,
                                                tlsOptions: self.originalTLSOptions)

        @inline(__always)
        func setupChildChannel() -> EventLoopFuture<Void> {
            return self.childChannelOptions.applyAll(channel: newChannel).then { () -> EventLoopFuture<Void> in
                assert(childLoop.inEventLoop)
                return childInitializer(newChannel)
            }
        }

        @inline(__always)
        func fireThroughPipeline(_ future: EventLoopFuture<Void>) {
            assert(ctxEventLoop.inEventLoop)
            future.then { (_) -> EventLoopFuture<Void> in
                assert(ctxEventLoop.inEventLoop)
                guard ctx.channel.isActive else {
                    return newChannel.close().thenThrowing {
                        throw ChannelError.ioOnClosedChannel
                    }
                }
                ctx.fireChannelRead(self.wrapInboundOut(newChannel))
                return ctx.eventLoop.newSucceededFuture(result: ())
            }.whenFailure { error in
                assert(ctx.eventLoop.inEventLoop)
                _ = newChannel.close()
                ctx.fireErrorCaught(error)
            }
        }

        if childLoop === ctxEventLoop {
            fireThroughPipeline(setupChildChannel())
        } else {
            fireThroughPipeline(childLoop.submit {
                return setupChildChannel()
                }.then { $0 }.hopTo(eventLoop: ctxEventLoop))
        }
    }
}
