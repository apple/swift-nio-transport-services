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
import NIOCore
import Dispatch
import Network

/// A ``NIOTSListenerBootstrap`` is an easy way to bootstrap a `NIOTSListenerChannel` when creating network servers.
///
/// Example:
///
/// ```swift
///     let group = NIOTSEventLoopGroup()
///     defer {
///         try! group.syncShutdownGracefully()
///     }
///     let bootstrap = NIOTSListenerBootstrap(group: group)
///         // Specify backlog and enable SO_REUSEADDR for the server itself
///         .serverChannelOption(ChannelOptions.backlog, value: 256)
///         .serverChannelOption(ChannelOptions.socketOption(.reuseaddr), value: 1)
///
///         // Set the handlers that are applied to the accepted child `Channel`s.
///         .childChannelInitializer { channel in
///             // Ensure we don't read faster then we can write by adding the BackPressureHandler into the pipeline.
///             channel.pipeline.addHandler(BackPressureHandler()).flatMap { () in
///                 // make sure to instantiate your `ChannelHandlers` inside of
///                 // the closure as it will be invoked once per connection.
///                 channel.pipeline.addHandler(MyChannelHandler())
///             }
///         }
///     let channel = try! bootstrap.bind(host: host, port: port).wait()
///     /* the server will now be accepting connections */
///
///     try! channel.closeFuture.wait() // wait forever as we never close the Channel
/// ```
///
/// The `EventLoopFuture` returned by `bind` will fire with a `NIOTSListenerChannel`. This is the channel that owns the
/// listening socket. Each time it accepts a new connection it will fire a `NIOTSConnectionChannel` through the
/// `ChannelPipeline` via `fireChannelRead`: as a result, the `NIOTSListenerChannel` operates on `Channel`s as inbound
/// messages. Outbound messages are not supported on a `NIOTSListenerChannel` which means that each write attempt will
/// fail.
///
/// Accepted `NIOTSConnectionChannel`s operate on `ByteBuffer` as inbound data, and `IOData` as outbound data.
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
public final class NIOTSListenerBootstrap {
    private let group: EventLoopGroup
    private let childGroup: EventLoopGroup
    private var serverChannelInit: ((Channel) -> EventLoopFuture<Void>)?
    private var childChannelInit: ((Channel) -> EventLoopFuture<Void>)?
    private var serverChannelOptions = ChannelOptions.Storage()
    private var childChannelOptions = ChannelOptions.Storage()
    private var serverQoS: DispatchQoS?
    private var childQoS: DispatchQoS?
    private var tcpOptions: NWProtocolTCP.Options = .init()
    private var tlsOptions: NWProtocolTLS.Options?
    private var bindTimeout: TimeAmount?

    /// Create a ``NIOTSListenerBootstrap`` for the `EventLoopGroup` `group`.
    ///
    /// This initializer only exists to be more in-line with the NIO core bootstraps, in that they
    /// may be constructed with an `EventLoopGroup` and by extension an `EventLoop`. As such an
    /// existing `NIOTSEventLoop` may be used to initialize this bootstrap. Where possible the
    /// initializers accepting ``NIOTSEventLoopGroup`` should be used instead to avoid the wrong
    /// type being used.
    ///
    /// > Note: The "real" solution is described in https://github.com/apple/swift-nio/issues/674.
    ///
    /// - parameters:
    ///     - group: The `EventLoopGroup` to use for the `NIOTSListenerChannel`.
    public convenience init(group: EventLoopGroup) {
        self.init(group: group, childGroup: group)
    }

    /// Create a ``NIOTSListenerBootstrap`` for the ``NIOTSEventLoopGroup`` `group`.
    ///
    /// - parameters:
    ///     - group: The ``NIOTSEventLoopGroup`` to use for the `NIOTSListenerChannel`.
    public convenience init(group: NIOTSEventLoopGroup) {
        self.init(group: group as EventLoopGroup)
    }

    /// Create a ``NIOTSListenerBootstrap``.
    ///
    /// This initializer only exists to be more in-line with the NIO core bootstraps, in that they
    /// may be constructed with an `EventLoopGroup` and by extension an `EventLoop`. As such an
    /// existing `NIOTSEventLoop` may be used to initialize this bootstrap. Where possible the
    /// initializers accepting ``NIOTSEventLoopGroup`` should be used instead to avoid the wrong
    /// type being used.
    ///
    /// > Note: The "real" solution is described in https://github.com/apple/swift-nio/issues/674.
    ///
    /// - parameters:
    ///     - group: The `EventLoopGroup` to use for the `bind` of the `NIOTSListenerChannel`
    ///         and to accept new `NIOTSConnectionChannel`s with.
    ///     - childGroup: The `EventLoopGroup` to run the accepted `NIOTSConnectionChannel`s on.
    public convenience init(group: EventLoopGroup, childGroup: EventLoopGroup) {
        guard NIOTSBootstraps.isCompatible(group: group) && NIOTSBootstraps.isCompatible(group: childGroup) else {
            preconditionFailure("NIOTSListenerBootstrap is only compatible with NIOTSEventLoopGroup and " +
                                "NIOTSEventLoop. You tried constructing one with group: \(group) and " +
                                "childGroup: \(childGroup) at least one of which is incompatible.")
        }

        self.init(validatingGroup: group, childGroup: childGroup)!
    }

    /// Create a ``NIOTSListenerBootstrap`` on the `EventLoopGroup` `group` which accepts `Channel`s on `childGroup`,
    /// validating that the `EventLoopGroup`s are compatible with ``NIOTSListenerBootstrap``.
    ///
    /// - parameters:
    ///     - group: The `EventLoopGroup` to use for the `bind` of the `NIOTSListenerChannel`
    ///         and to accept new `NIOTSConnectionChannel`s with.
    ///     - childGroup: The `EventLoopGroup` to run the accepted `NIOTSConnectionChannel`s on.
    public init?(validatingGroup group: EventLoopGroup, childGroup: EventLoopGroup? = nil) {
        let childGroup = childGroup ?? group
        guard NIOTSBootstraps.isCompatible(group: group) && NIOTSBootstraps.isCompatible(group: childGroup) else {
            return nil
        }

        self.group = group
        self.childGroup = childGroup

        self.serverChannelOptions.append(key: ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
        self.childChannelOptions.append(key: ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
    }

    /// Create a ``NIOTSListenerBootstrap``.
    ///
    /// - parameters:
    ///     - group: The ``NIOTSEventLoopGroup`` to use for the `bind` of the `NIOTSListenerChannel`
    ///         and to accept new `NIOTSConnectionChannel`s with.
    ///     - childGroup: The ``NIOTSEventLoopGroup`` to run the accepted `NIOTSConnectionChannel`s on.
    public convenience init(group: NIOTSEventLoopGroup, childGroup: NIOTSEventLoopGroup) {
        self.init(group: group as EventLoopGroup, childGroup: childGroup as EventLoopGroup)
    }

    /// Initialize the `NIOTSListenerChannel` with `initializer`. The most common task in initializer is to add
    /// `ChannelHandler`s to the `ChannelPipeline`.
    ///
    /// The `NIOTSListenerChannel` uses the accepted `NIOTSConnectionChannel`s as inbound messages.
    ///
    /// > Note: To set the initializer for the accepted `NIOTSConnectionChannel`s, look at
    ///     ``childChannelInitializer(_:)``.
    ///
    /// - parameters:
    ///     - initializer: A closure that initializes the provided `Channel`.
    public func serverChannelInitializer(_ initializer: @escaping (Channel) -> EventLoopFuture<Void>) -> Self {
        self.serverChannelInit = initializer
        return self
    }

    /// Initialize the accepted `NIOTSConnectionChannel`s with `initializer`. The most common task in initializer is to add
    /// `ChannelHandler`s to the `ChannelPipeline`. Note that if the `initializer` fails then the error will be
    /// fired in the *parent* channel.
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
    /// > Note: To specify options for the accepted `NIOTSConnectionChannel`s, look at ``childChannelOption(_:value:)``.
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
    ///
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
    public func tcpOptions(_ options: NWProtocolTCP.Options) -> Self {
        self.tcpOptions = options
        return self
    }

    /// Specifies the TLS options to use on the child `Channel`s.
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
        let validPortRange = Int(UInt16.min)...Int(UInt16.max)
        guard validPortRange.contains(port) else {
            return self.group.next().makeFailedFuture(NIOTSErrors.InvalidPort(port: port))
        }

        return self.bind0(shouldRegister: true) { (channel, promise) in
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
        return self.bind0(shouldRegister: true) { (channel, promise) in
            channel.bind(to: address, promise: promise)
        }
    }

    /// Bind the `NIOTSListenerChannel` to a UNIX Domain Socket.
    ///
    /// - parameters:
    ///     - unixDomainSocketPath: The _Unix domain socket_ path to bind to. `unixDomainSocketPath` must not exist, it will be created by the system.
    public func bind(unixDomainSocketPath: String) -> EventLoopFuture<Channel> {
        return self.bind0(shouldRegister: true) { (channel, promise) in
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
        return self.bind0(shouldRegister: true) { (channel, promise) in
            channel.triggerUserOutboundEvent(NIOTSNetworkEvents.BindToNWEndpoint(endpoint: endpoint), promise: promise)
        }
    }

    /// Bind the `NIOTSListenerChannel` to an existing `NWListener`.
    ///
    /// - parameters:
    ///     - listener: The NWListener to wrap.
    public func withNWListener(_ listener:NWListener) -> EventLoopFuture<Channel>{
        return self.bind0(existingNWListener: listener,shouldRegister: false) { channel, promise in
            channel.registerAlreadyConfigured0(promise: promise)
        }
    }

    private func bind0(existingNWListener: NWListener? = nil, shouldRegister: Bool, _ binder: @escaping (NIOTSListenerChannel, EventLoopPromise<Void>) -> Void) -> EventLoopFuture<Channel> {
        let eventLoop = self.group.next() as! NIOTSEventLoop
        let serverChannelInit = self.serverChannelInit ?? { _ in eventLoop.makeSucceededFuture(()) }
        let childChannelInit = self.childChannelInit
        let serverChannelOptions = self.serverChannelOptions
        let childChannelOptions = self.childChannelOptions

        let serverChannel: NIOTSListenerChannel
        if let newListener = existingNWListener {
            serverChannel = NIOTSListenerChannel(
                wrapping: newListener,
                on: self.group.next() as! NIOTSEventLoop,
                qos: self.serverQoS,
                tcpOptions: self.tcpOptions,
                tlsOptions: self.tlsOptions,
                childLoopGroup: self.childGroup,
                childChannelQoS: self.childQoS,
                childTCPOptions: self.tcpOptions,
                childTLSOptions: self.tlsOptions
            )
        } else {
            serverChannel = NIOTSListenerChannel(
                eventLoop: eventLoop,
                qos: self.serverQoS,
                tcpOptions: self.tcpOptions,
                tlsOptions: self.tlsOptions,
                childLoopGroup: self.childGroup,
                childChannelQoS: self.childQoS,
                childTCPOptions: self.tcpOptions,
                childTLSOptions: self.tlsOptions
            )
        }

        return eventLoop.submit {
            return serverChannelOptions.applyAllChannelOptions(to: serverChannel).flatMap {
                serverChannelInit(serverChannel)
            }.flatMap {
                eventLoop.assertInEventLoop()
                return serverChannel.pipeline.addHandler(AcceptHandler<NIOTSConnectionChannel>(childChannelInitializer: childChannelInit,
                                                                       childChannelOptions: childChannelOptions))
            }.flatMap {
                if shouldRegister{
                     return serverChannel.register()
                } else {
                    return eventLoop.makeSucceededVoidFuture()
                }
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

// MARK: Async bind methods with arbitrary payload

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOTSListenerBootstrap {
    /// Bind the `NIOTSListenerChannel` to `host` and `port`.
    ///
    /// - Parameters:
    ///   - host: The host to bind on.
    ///   - port: The port to bind on.
    ///   - serverBackpressureStrategy: The back pressure strategy used by the server socket channel.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `bind`
    ///     method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func bind<Output: Sendable>(
        host: String,
        port: Int,
        serverBackpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil,
        childChannelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> NIOAsyncChannel<Output, Never> {
        let validPortRange = Int(UInt16.min)...Int(UInt16.max)
        guard validPortRange.contains(port) else {
            throw NIOTSErrors.InvalidPort(port: port)
        }

        return try await self.bind0(
            serverBackpressureStrategy: serverBackpressureStrategy,
            childChannelInitializer: childChannelInitializer,
            registration: { (serverChannel, promise) in
                serverChannel.register().whenComplete { result in
                    switch result {
                    case .success:
                        do {
                            // NWListener does not actually resolve hostname-based NWEndpoints
                            // for use with requiredLocalEndpoint, so we fall back to
                            // SocketAddress for this.
                            let address = try SocketAddress.makeAddressResolvingHost(host, port: port)
                            serverChannel.bind(to: address, promise: promise)
                        } catch {
                            promise.fail(error)
                        }
                    case .failure(let error):
                        promise.fail(error)
                    }
                }
            }
        ).get()
    }

    /// Bind the `NIOTSListenerChannel` to `address`.
    ///
    /// - Parameters:
    ///   - address: The `SocketAddress` to bind on.
    ///   - serverBackpressureStrategy: The back pressure strategy used by the server socket channel.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `bind`
    ///     method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func bind<Output: Sendable>(
        to address: SocketAddress,
        serverBackpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil,
        childChannelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> NIOAsyncChannel<Output, Never> {
        return try await self.bind0(
            serverBackpressureStrategy: serverBackpressureStrategy,
            childChannelInitializer: childChannelInitializer,
            registration: { (serverChannel, promise) in
                serverChannel.register().whenComplete { result in
                    switch result {
                    case .success:
                        serverChannel.bind(to: address, promise: promise)
                    case .failure(let error):
                        promise.fail(error)
                    }
                }
            }
        ).get()
    }

    /// Bind the `NIOTSListenerChannel` to a given `NWEndpoint`.
    ///
    /// - Parameters:
    ///   - endpoint: The `NWEndpoint` to bind this channel to.
    ///   - serverBackpressureStrategy: The back pressure strategy used by the server socket channel.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `bind`
    ///     method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func bind<Output: Sendable>(
        endpoint: NWEndpoint,
        serverBackpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil,
        childChannelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> NIOAsyncChannel<Output, Never> {
        return try await self.bind0(
            serverBackpressureStrategy: serverBackpressureStrategy,
            childChannelInitializer: childChannelInitializer,
            registration: { (serverChannel, promise) in
                serverChannel.register().whenComplete { result in
                    switch result {
                    case .success:
                        serverChannel.triggerUserOutboundEvent(NIOTSNetworkEvents.BindToNWEndpoint(endpoint: endpoint), promise: promise)
                    case .failure(let error):
                        promise.fail(error)
                    }
                }
            }
        ).get()
    }

    /// Bind the `NIOTSListenerChannel` to an existing `NWListener`.
    ///
    /// - Parameters:
    ///   - listener: The NWListener to wrap.
    ///   - serverBackpressureStrategy: The back pressure strategy used by the server socket channel.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `bind`
    ///     method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func withNWListener<Output: Sendable>(
        _ listener: NWListener,
        serverBackpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil,
        childChannelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> NIOAsyncChannel<Output, Never> {
        return try await self.bind0(
            existingNWListener: listener,
            serverBackpressureStrategy: serverBackpressureStrategy,
            childChannelInitializer: childChannelInitializer,
            registration: { (serverChannel, promise) in
                serverChannel.registerAlreadyConfigured0(promise: promise)
            }
        ).get()
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    private func bind0<ChannelInitializerResult>(
        existingNWListener: NWListener? = nil,
        serverBackpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark?,
        childChannelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<ChannelInitializerResult>,
        registration: @escaping (NIOTSListenerChannel, EventLoopPromise<Void>) -> Void
    ) -> EventLoopFuture<NIOAsyncChannel<ChannelInitializerResult, Never>> {
        let eventLoop = self.group.next() as! NIOTSEventLoop
        let serverChannelInit = self.serverChannelInit ?? { _ in eventLoop.makeSucceededFuture(()) }
        let childChannelInit = self.childChannelInit
        let serverChannelOptions = self.serverChannelOptions
        let childChannelOptions = self.childChannelOptions

        let serverChannel: NIOTSListenerChannel
        if let newListener = existingNWListener {
            serverChannel = NIOTSListenerChannel(wrapping: newListener,
                                                     on: self.group.next() as! NIOTSEventLoop,
                                                     qos: self.serverQoS,
                                                     tcpOptions: self.tcpOptions,
                                                     tlsOptions: self.tlsOptions,
                                                     childLoopGroup: self.childGroup,
                                                     childChannelQoS: self.childQoS,
                                                     childTCPOptions: self.tcpOptions,
                                                     childTLSOptions: self.tlsOptions)
        } else {
            serverChannel = NIOTSListenerChannel(eventLoop: eventLoop,
                                                     qos: self.serverQoS,
                                                     tcpOptions: self.tcpOptions,
                                                     tlsOptions: self.tlsOptions,
                                                     childLoopGroup: self.childGroup,
                                                     childChannelQoS: self.childQoS,
                                                     childTCPOptions: self.tcpOptions,
                                                     childTLSOptions: self.tlsOptions)
        }

        return eventLoop.submit {
            serverChannelOptions.applyAllChannelOptions(to: serverChannel).flatMap {
                serverChannelInit(serverChannel)
            }.flatMap { (_) -> EventLoopFuture<NIOAsyncChannel<ChannelInitializerResult, Never>> in
                do {
                    try serverChannel.pipeline.syncOperations.addHandler(
                        AcceptHandler<NIOTSConnectionChannel>(childChannelInitializer: childChannelInit, childChannelOptions: childChannelOptions),
                        name: "AcceptHandler"
                    )
                    let asyncChannel = try NIOAsyncChannel<ChannelInitializerResult, Never>
                        ._wrapAsyncChannelWithTransformations(
                            synchronouslyWrapping: serverChannel,
                            backPressureStrategy: serverBackpressureStrategy,
                            channelReadTransformation: { channel -> EventLoopFuture<(ChannelInitializerResult)> in
                                // The channelReadTransformation is run on the EL of the server channel
                                // We have to make sure that we execute child channel initializer on the
                                // EL of the child channel.
                                channel.eventLoop.flatSubmit {
                                    childChannelInitializer(channel)
                                }
                            }
                        )

                    let bindPromise = eventLoop.makePromise(of: Void.self)
                    registration(serverChannel, bindPromise)

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
                        .map { (_) -> NIOAsyncChannel<ChannelInitializerResult, Never> in asyncChannel
                    }
                } catch {
                    return eventLoop.makeFailedFuture(error)
                }
            }.flatMapError { error -> EventLoopFuture<NIOAsyncChannel<ChannelInitializerResult, Never>> in
                serverChannel.close0(error: error, mode: .all, promise: nil)
                return eventLoop.makeFailedFuture(error)
            }
        }.flatMap {
            $0
        }
    }
}

#endif
