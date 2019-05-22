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

#if canImport(Network)
import NIO
import Dispatch
import Network

@available(OSX 10.14, iOS 12.0, tvOS 12.0, *)
public final class NIOTSListenerBootstrap {
    private let group: EventLoopGroup
    private let childGroup: NIOTSEventLoopGroup
    private var serverChannelInit: ((Channel) -> EventLoopFuture<Void>)?
    private var childChannelInit: ((Channel) -> EventLoopFuture<Void>)?
    private var serverChannelOptions = ChannelOptionsStorage()
    private var childChannelOptions = ChannelOptionsStorage()
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
    public func serverChannelOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> Self {
        self.serverChannelOptions.append(key: option, value: value)
        return self
    }

    /// Specifies a `ChannelOption` to be applied to the accepted `NIOTSConnectionChannel`s.
    ///
    /// - parameters:
    ///     - option: The option to be applied.
    ///     - value: The value for the option.
    public func childChannelOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> Self {
        self.childChannelOptions.append(key: option, value: value)
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
            let p: EventLoopPromise<Void> = channel.eventLoop.makePromise()
            do {
                // NWListener does not actually resolve hostname-based NWEndpoints
                // for use with requiredLocalEndpoint, so we fall back to
                // SocketAddress for this.
                let address = try SocketAddress.makeAddressResolvingHost(host, port: port)
                channel.bind(to: address, promise: p)
            } catch {
                p.fail(error)
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
            let p: EventLoopPromise<Void> = channel.eventLoop.makePromise()
            do {
                let address = try SocketAddress(unixDomainSocketPath: unixDomainSocketPath)
                channel.bind(to: address, promise: p)
            } catch {
                p.fail(error)
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
        let serverChannelInit = self.serverChannelInit ?? { _ in eventLoop.makeSucceededFuture(()) }
        let childChannelInit = self.childChannelInit
        let serverChannelOptions = self.serverChannelOptions
        let childChannelOptions = self.childChannelOptions

        let serverChannel = NIOTSListenerChannel(eventLoop: eventLoop,
                                                 qos: self.serverQoS,
                                                 tcpOptions: self.tcpOptions,
                                                 tlsOptions: self.tlsOptions,
                                                 childLoopGroup: self.childGroup,
                                                 childChannelQoS: self.childQoS,
                                                 childTCPOptions: self.tcpOptions,
                                                 childTLSOptions: self.tlsOptions)

        return eventLoop.submit {
            return serverChannelOptions.applyAllChannelOptions(to: serverChannel).flatMap {
                serverChannelInit(serverChannel)
            }.flatMap {
                serverChannel.pipeline.addHandler(AcceptHandler(childChannelInitializer: childChannelInit,
                                                                  childChannelOptions: childChannelOptions))
            }.flatMap {
                serverChannel.register()
            }.flatMap {
                binder(serverChannel)
            }.map {
                serverChannel as Channel
            }.flatMapError { error in
                serverChannel.close0(error: error, mode: .all, promise: nil)
                return eventLoop.makeFailedFuture(error)
            }
        }.flatMap {
            $0
        }
    }
}


@available(OSX 10.14, iOS 12.0, tvOS 12.0, *)
private class AcceptHandler: ChannelInboundHandler {
    typealias InboundIn = NIOTSConnectionChannel
    typealias InboundOut = NIOTSConnectionChannel

    private let childChannelInitializer: ((Channel) -> EventLoopFuture<Void>)?
    private let childChannelOptions: ChannelOptionsStorage

    init(childChannelInitializer: ((Channel) -> EventLoopFuture<Void>)?,
         childChannelOptions: ChannelOptionsStorage) {
        self.childChannelInitializer = childChannelInitializer
        self.childChannelOptions = childChannelOptions
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let newChannel = self.unwrapInboundIn(data)
        let childLoop = newChannel.eventLoop
        let ctxEventLoop = context.eventLoop
        let childInitializer = self.childChannelInitializer ?? { _ in childLoop.makeSucceededFuture(()) }


        @inline(__always)
        func setupChildChannel() -> EventLoopFuture<Void> {
            return self.childChannelOptions.applyAllChannelOptions(to: newChannel).flatMap { () -> EventLoopFuture<Void> in
                childLoop.assertInEventLoop()
                return childInitializer(newChannel)
            }
        }

        @inline(__always)
        func fireThroughPipeline(_ future: EventLoopFuture<Void>) {
            ctxEventLoop.assertInEventLoop()
            future.flatMap { (_) -> EventLoopFuture<Void> in
                ctxEventLoop.assertInEventLoop()
                guard context.channel.isActive else {
                    return newChannel.close().flatMapThrowing {
                        throw ChannelError.ioOnClosedChannel
                    }
                }
                context.fireChannelRead(self.wrapInboundOut(newChannel))
                return context.eventLoop.makeSucceededFuture(())
            }.whenFailure { error in
                context.eventLoop.assertInEventLoop()
                _ = newChannel.close()
                context.fireErrorCaught(error)
            }
        }

        if childLoop === ctxEventLoop {
            fireThroughPipeline(setupChildChannel())
        } else {
            fireThroughPipeline(childLoop.submit {
                return setupChildChannel()
                }.flatMap { $0 }.hop(to: ctxEventLoop))
        }
    }
}
#endif
