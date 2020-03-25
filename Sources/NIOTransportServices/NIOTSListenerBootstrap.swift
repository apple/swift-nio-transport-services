//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if canImport(Network)
import NIO
import Dispatch
import Network

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
public final class NIOTSListenerBootstrap {
    private let group: EventLoopGroup
    private let childGroup: EventLoopGroup
    private var serverChannelInit: ((Channel) -> EventLoopFuture<Void>)?
    private var childChannelInit: ((Channel) -> EventLoopFuture<Void>)?
    private var serverChannelOptions = ChannelOptionsStorage()
    private var childChannelOptions = ChannelOptionsStorage()
    private var serverQoS: DispatchQoS?
    private var childQoS: DispatchQoS?
    private var tcpOptions: NWProtocolTCP.Options = .init()
    private var tlsOptions: NWProtocolTLS.Options?
    private var bindTimeout: TimeAmount?

    /// Create a `NIOTSListenerBootstrap` for the `EventLoopGroup` `group`.
    ///
    /// This initializer only exists to be more in-line with the NIO core bootstraps, in that they
    /// may be constructed with an `EventLoopGroup` and by extenstion an `EventLoop`. As such an
    /// existing `NIOTSEventLoop` may be used to initialize this bootstrap. Where possible the
    /// initializers accepting `NIOTSEventLoopGroup` should be used instead to avoid the wrong
    /// type being used.
    ///
    /// Note that the "real" solution is described in https://github.com/apple/swift-nio/issues/674.
    ///
    /// - parameters:
    ///     - group: The `EventLoopGroup` to use for the `ServerSocketChannel`.
    public convenience init(group: EventLoopGroup) {
        self.init(group: group, childGroup: group)

        self.serverChannelOptions.append(key: ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
        self.childChannelOptions.append(key: ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
    }

    /// Create a `NIOTSListenerBootstrap` for the `NIOTSEventLoopGroup` `group`.
    ///
    /// - parameters:
    ///     - group: The `NIOTSEventLoopGroup` to use for the `ServerSocketChannel`.
    public convenience init(group: NIOTSEventLoopGroup) {
        self.init(group: group as EventLoopGroup)
    }

    /// Create a `NIOTSListenerBootstrap`.
    ///
    /// This initializer only exists to be more in-line with the NIO core bootstraps, in that they
    /// may be constructed with an `EventLoopGroup` and by extenstion an `EventLoop`. As such an
    /// existing `NIOTSEventLoop` may be used to initialize this bootstrap. Where possible the
    /// initializers accepting `NIOTSEventLoopGroup` should be used instead to avoid the wrong
    /// type being used.
    ///
    /// Note that the "real" solution is described in https://github.com/apple/swift-nio/issues/674.
    ///
    /// - parameters:
    ///     - group: The `EventLoopGroup` to use for the `bind` of the `NIOTSListenerChannel`
    ///         and to accept new `NIOTSConnectionChannel`s with.
    ///     - childGroup: The `EventLoopGroup` to run the accepted `NIOTSConnectionChannel`s on.
    public init(group: EventLoopGroup, childGroup: EventLoopGroup) {
        self.group = group
        self.childGroup = childGroup

        self.serverChannelOptions.append(key: ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
        self.childChannelOptions.append(key: ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
    }

    /// Create a `NIOTSListenerBootstrap`.
    ///
    /// - parameters:
    ///     - group: The `NIOTSEventLoopGroup` to use for the `bind` of the `NIOTSListenerChannel`
    ///         and to accept new `NIOTSConnectionChannel`s with.
    ///     - childGroup: The `NIOTSEventLoopGroup` to run the accepted `NIOTSConnectionChannel`s on.
    public convenience init(group: NIOTSEventLoopGroup, childGroup: NIOTSEventLoopGroup) {
        self.init(group: group as EventLoopGroup, childGroup: childGroup as EventLoopGroup)
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

    /// Specifies a timeout to apply to a bind attempt.
    //
    /// - parameters:
    ///     - timeout: The timeout that will apply to the bind attempt.
    public func bindTimeout(_ timeout: TimeAmount) -> Self {
        self.bindTimeout = timeout
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
        return self.bind0 { (channel, promise) in
            do {
                // NWListener does not actually resolve hostname-based NWEndpoints
                // for use with requiredLocalEndpoint, so we fall back to
                // SocketAddress for this.
                let address = try SocketAddress.makeAddressResolvingHost(host, port: port)
                channel.bind(to: address, promise: promise)
            } catch {
                promise.fail(error)
            }
        }
    }

    /// Bind the `NIOTSListenerChannel` to `address`.
    ///
    /// - parameters:
    ///     - address: The `SocketAddress` to bind on.
    public func bind(to address: SocketAddress) -> EventLoopFuture<Channel> {
        return self.bind0 { (channel, promise) in
            channel.bind(to: address, promise: promise)
        }
    }

    /// Bind the `NIOTSListenerChannel` to a UNIX Domain Socket.
    ///
    /// - parameters:
    ///     - unixDomainSocketPath: The _Unix domain socket_ path to bind to. `unixDomainSocketPath` must not exist, it will be created by the system.
    public func bind(unixDomainSocketPath: String) -> EventLoopFuture<Channel> {
        return self.bind0 { (channel, promise) in
            do {
                let address = try SocketAddress(unixDomainSocketPath: unixDomainSocketPath)
                channel.bind(to: address, promise: promise)
            } catch {
                promise.fail(error)
            }
        }
    }

    /// Bind the `NIOTSListenerChannel` to a given `NWEndpoint`.
    ///
    /// - parameters:
    ///     - endpoint: The `NWEndpoint` to bind this channel to.
    public func bind(endpoint: NWEndpoint) -> EventLoopFuture<Channel> {
        return self.bind0 { (channel, promise) in
            channel.triggerUserOutboundEvent(NIOTSNetworkEvents.BindToNWEndpoint(endpoint: endpoint), promise: promise)
        }
    }

    private func bind0(_ binder: @escaping (Channel, EventLoopPromise<Void>) -> Void) -> EventLoopFuture<Channel> {
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
                eventLoop.assertInEventLoop()
                return serverChannel.pipeline.addHandler(AcceptHandler(childChannelInitializer: childChannelInit,
                                                                       childChannelOptions: childChannelOptions))
            }.flatMap {
                serverChannel.register()
            }.flatMap {
                let bindPromise = eventLoop.makePromise(of: Void.self)
                binder(serverChannel, bindPromise)

                if let bindTimeout = self.bindTimeout {
                    let cancelTask = eventLoop.scheduleTask(in: bindTimeout) {
                        bindPromise.fail(NIOTSErrors.BindTimeout(timeout: bindTimeout))
                        serverChannel.close(promise: nil)
                    }

                    bindPromise.futureResult.whenComplete { (_: Result<Void, Error>) in
                        cancelTask.cancel()
                    }
                }
                return bindPromise.futureResult
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


@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
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
            fireThroughPipeline(childLoop.flatSubmit {
                return setupChildChannel()
            }.hop(to: ctxEventLoop))
        }
    }
}
#endif
