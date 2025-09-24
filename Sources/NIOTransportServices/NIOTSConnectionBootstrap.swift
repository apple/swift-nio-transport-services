//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2022 Apple Inc. and the SwiftNIO project authors
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

/// A ``NIOTSConnectionBootstrap`` is an easy way to bootstrap a channel when creating network clients.
///
/// Usually you re-use a ``NIOTSConnectionBootstrap`` once you set it up, calling `connect` multiple times on the same bootstrap.
/// This way you ensure that the same `EventLoop`s will be shared across all your connections.
///
/// Example:
///
/// ```swift
///     let group = NIOTSEventLoopGroup()
///     defer {
///         try! group.syncShutdownGracefully()
///     }
///     let bootstrap = NIOTSConnectionBootstrap(group: group)
///         .channelInitializer { channel in
///             channel.pipeline.addHandler(MyChannelHandler())
///         }
///     try! bootstrap.connect(host: "example.org", port: 12345).wait()
///     /* the Channel is now connected */
/// ```
///
/// The connected channel will operate on `ByteBuffer` as inbound and on `IOData` as outbound messages.
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
public final class NIOTSConnectionBootstrap {
    private let group: EventLoopGroup
    private var _channelInitializer: (@Sendable (Channel) -> EventLoopFuture<Void>)
    private var channelInitializer: (@Sendable (Channel) -> EventLoopFuture<Void>) {
        if let protocolHandlers = self.protocolHandlers {
            let channelInitializer = self._channelInitializer
            return { channel in
                channelInitializer(channel).flatMap {
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandlers(protocolHandlers(), position: .first)
                    }
                }
            }
        } else {
            return self._channelInitializer
        }
    }
    private var connectTimeout: TimeAmount = TimeAmount.seconds(10)
    private var channelOptions = ChannelOptions.Storage()
    private var qos: DispatchQoS?
    private var tcpOptions: NWProtocolTCP.Options = .init()
    private var tlsOptions: NWProtocolTLS.Options?
    private var protocolHandlers: (@Sendable () -> [ChannelHandler])? = nil
    private var nwParametersConfigurator: (@Sendable (NWParameters) -> Void)?

    /// Create a ``NIOTSConnectionBootstrap`` on the `EventLoopGroup` `group`.
    ///
    /// The `EventLoopGroup` `group` must be compatible, otherwise the program will crash. ``NIOTSConnectionBootstrap`` is
    /// compatible only with ``NIOTSEventLoopGroup`` as well as the `EventLoop`s returned by
    /// ``NIOTSEventLoopGroup/next()``. See ``init(validatingGroup:)`` for a fallible initializer for
    /// situations where it's impossible to tell ahead of time if the `EventLoopGroup` is compatible or not.
    ///
    /// - parameters:
    ///     - group: The `EventLoopGroup` to use.
    public convenience init(group: EventLoopGroup) {
        guard NIOTSBootstraps.isCompatible(group: group) else {
            preconditionFailure(
                "NIOTSConnectionBootstrap is only compatible with NIOTSEventLoopGroup and "
                    + "NIOTSEventLoop. You tried constructing one with \(group) which is incompatible."
            )
        }

        self.init(validatingGroup: group)!
    }

    /// Create a ``NIOTSConnectionBootstrap`` on the ``NIOTSEventLoopGroup`` `group`.
    ///
    /// - parameters:
    ///     - group: The ``NIOTSEventLoopGroup`` to use.
    public convenience init(group: NIOTSEventLoopGroup) {
        self.init(group: group as EventLoopGroup)
    }

    /// Create a ``NIOTSConnectionBootstrap`` on the ``NIOTSEventLoopGroup`` `group`, validating
    /// that the `EventLoopGroup` is compatible with ``NIOTSConnectionBootstrap``.
    ///
    /// - parameters:
    ///     - group: The `EventLoopGroup` to use.
    public init?(validatingGroup group: EventLoopGroup) {
        guard NIOTSBootstraps.isCompatible(group: group) else {
            return nil
        }

        self.group = group
        self.channelOptions.append(key: ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
        self._channelInitializer = { channel in channel.eventLoop.makeSucceededVoidFuture() }
    }

    /// Initialize the connected channel with `initializer`. The most common task in initializer is to add
    /// `ChannelHandler`s to the `ChannelPipeline`.
    ///
    /// The connected `Channel` will operate on `ByteBuffer` as inbound and `IOData` as outbound messages.
    ///
    /// - parameters:
    ///     - handler: A closure that initializes the provided `Channel`.
    @preconcurrency
    public func channelInitializer(_ handler: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) -> Self {
        self._channelInitializer = handler
        return self
    }

    /// Specifies a `ChannelOption` to be applied to the channel.
    ///
    /// - parameters:
    ///     - option: The option to be applied.
    ///     - value: The value for the option.
    public func channelOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> Self {
        channelOptions.append(key: option, value: value)
        return self
    }

    /// Specifies a timeout to apply to a connection attempt.
    //
    /// - parameters:
    ///     - timeout: The timeout that will apply to the connection attempt.
    public func connectTimeout(_ timeout: TimeAmount) -> Self {
        self.connectTimeout = timeout
        return self
    }

    /// Specifies a QoS to use for this connection, instead of the default QoS for the
    /// event loop.
    ///
    /// This allows unusually high or low priority workloads to be appropriately scheduled.
    public func withQoS(_ qos: DispatchQoS) -> Self {
        self.qos = qos
        return self
    }

    /// Specifies the TCP options to use on the `Channel`s.
    public func tcpOptions(_ options: NWProtocolTCP.Options) -> Self {
        self.tcpOptions = options
        return self
    }

    /// Specifies the TLS options to use on the `Channel`s.
    public func tlsOptions(_ options: NWProtocolTLS.Options) -> Self {
        self.tlsOptions = options
        return self
    }

    /// Specifies a type of Multipath service to use for this connection, instead of the default
    /// service type for the event loop.
    public func withMultipath(_ type: NWParameters.MultipathServiceType) -> Self {
        self.channelOption(NIOTSChannelOptions.multipathServiceType, value: type)
    }

    /// Customise the `NWParameters` to be used when creating the connection.
    public func configureNWParameters(
        _ configurator: @Sendable @escaping (NWParameters) -> Void
    ) -> Self {
        self.nwParametersConfigurator = configurator
        return self
    }

    /// Specify the `host` and `port` to connect to for the TCP `Channel` that will be established.
    ///
    /// - parameters:
    ///     - host: The host to connect to.
    ///     - port: The port to connect to.
    /// - returns: An `EventLoopFuture<Channel>` to deliver the `Channel` when connected.
    public func connect(host: String, port: Int) -> EventLoopFuture<Channel> {
        let validPortRange = Int(UInt16.min)...Int(UInt16.max)
        guard validPortRange.contains(port) else {
            return self.group.next().makeFailedFuture(NIOTSErrors.InvalidPort(port: port))
        }

        guard let actualPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return self.group.next().makeFailedFuture(NIOTSErrors.InvalidPort(port: port))
        }
        return self.connect(endpoint: NWEndpoint.hostPort(host: .init(host), port: actualPort))
    }

    /// Specify the `address` to connect to for the TCP `Channel` that will be established.
    ///
    /// - parameters:
    ///     - address: The address to connect to.
    /// - returns: An `EventLoopFuture<Channel>` to deliver the `Channel` when connected.
    public func connect(to address: SocketAddress) -> EventLoopFuture<Channel> {
        self.connect(shouldRegister: true) { channel, promise in
            channel.connect(to: address, promise: promise)
        }
    }

    /// Specify the `unixDomainSocket` path to connect to for the UDS `Channel` that will be established.
    ///
    /// - parameters:
    ///     - unixDomainSocketPath: The _Unix domain socket_ path to connect to.
    /// - returns: An `EventLoopFuture<Channel>` to deliver the `Channel` when connected.
    public func connect(unixDomainSocketPath: String) -> EventLoopFuture<Channel> {
        do {
            let address = try SocketAddress(unixDomainSocketPath: unixDomainSocketPath)
            return connect(to: address)
        } catch {
            return group.next().makeFailedFuture(error)
        }
    }

    /// Specify the `endpoint` to connect to for the TCP `Channel` that will be established.
    public func connect(endpoint: NWEndpoint) -> EventLoopFuture<Channel> {
        self.connect(shouldRegister: true) { channel, promise in
            channel.triggerUserOutboundEvent(
                NIOTSNetworkEvents.ConnectToNWEndpoint(endpoint: endpoint),
                promise: promise
            )
        }
    }

    /// Use a pre-existing `NWConnection` to connect a `Channel`.
    ///
    /// - parameters:
    ///     - connection: The NWConnection to wrap.
    /// - returns: An `EventLoopFuture<Channel>` to deliver the `Channel` when connected.
    public func withExistingNWConnection(_ connection: NWConnection) -> EventLoopFuture<Channel> {
        self.connect(existingNWConnection: connection, shouldRegister: false) { channel, promise in
            channel.registerAlreadyConfigured0(promise: promise)
        }
    }

    private func connect(
        existingNWConnection: NWConnection? = nil,
        shouldRegister: Bool,
        _ connectAction:
            @Sendable @escaping (
                NIOTSConnectionChannel,
                EventLoopPromise<Void>
            ) -> Void
    ) -> EventLoopFuture<Channel> {
        let conn: NIOTSConnectionChannel
        if let newConnection = existingNWConnection {
            conn = NIOTSConnectionChannel(
                wrapping: newConnection,
                on: self.group.next() as! NIOTSEventLoop,
                tcpOptions: self.tcpOptions,
                tlsOptions: self.tlsOptions,
                nwParametersConfigurator: self.nwParametersConfigurator
            )
        } else {
            conn = NIOTSConnectionChannel(
                eventLoop: self.group.next() as! NIOTSEventLoop,
                qos: self.qos,
                tcpOptions: self.tcpOptions,
                tlsOptions: self.tlsOptions,
                nwParametersConfigurator: self.nwParametersConfigurator
            )
        }
        let initializer = self.channelInitializer
        let channelOptions = self.channelOptions

        return conn.eventLoop.flatSubmit { [connectTimeout] in
            channelOptions.applyAllChannelOptions(to: conn).flatMap {
                initializer(conn)
            }.flatMap {
                conn.eventLoop.assertInEventLoop()
                if shouldRegister {
                    return conn.register()
                } else {
                    return conn.eventLoop.makeSucceededVoidFuture()
                }
            }.flatMap {
                let connectPromise: EventLoopPromise<Void> = conn.eventLoop.makePromise()
                connectAction(conn, connectPromise)
                let cancelTask = conn.eventLoop.scheduleTask(in: connectTimeout) {
                    connectPromise.fail(ChannelError.connectTimeout(connectTimeout))
                    conn.close(promise: nil)
                }

                connectPromise.futureResult.whenComplete { (_: Result<Void, Error>) in
                    cancelTask.cancel()
                }
                return connectPromise.futureResult
            }.map { conn }.flatMapErrorThrowing {
                conn.close(promise: nil)
                throw $0
            }
        }
    }

    /// Sets the protocol handlers that will be added to the front of the `ChannelPipeline` right after the
    /// `channelInitializer` has been called.
    ///
    /// Per bootstrap, you can only set the `protocolHandlers` once. Typically, `protocolHandlers` are used for the TLS
    /// implementation. Most notably, `NIOClientTCPBootstrap`, NIO's "universal bootstrap" abstraction, uses
    /// `protocolHandlers` to add the required `ChannelHandler`s for many TLS implementations.
    @preconcurrency
    public func protocolHandlers(_ handlers: @Sendable @escaping () -> [ChannelHandler]) -> Self {
        precondition(self.protocolHandlers == nil, "protocol handlers can only be set once")
        self.protocolHandlers = handlers
        return self
    }
}

// MARK: Async connect methods with arbitrary payload

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOTSConnectionBootstrap {
    /// Specify the `host` and `port` to connect to for the TCP `Channel` that will be established.
    ///
    /// - Parameters:
    ///   - host: The host to connect to.
    ///   - port: The port to connect to.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///     method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func connect<Output: Sendable>(
        host: String,
        port: Int,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> Output {
        let validPortRange = Int(UInt16.min)...Int(UInt16.max)
        guard validPortRange.contains(port), let actualPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw NIOTSErrors.InvalidPort(port: port)
        }

        return try await self.connect(
            endpoint: NWEndpoint.hostPort(host: .init(host), port: actualPort),
            channelInitializer: channelInitializer
        )
    }

    /// Specify the `address` to connect to for the TCP `Channel` that will be established.
    ///
    /// - Parameters:
    ///   - address: The address to connect to.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///     method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func connect<Output: Sendable>(
        to address: SocketAddress,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> Output {
        try await self.connect0(
            channelInitializer: channelInitializer,
            registration: { connectionChannel, promise in
                connectionChannel.register().whenComplete { result in
                    switch result {
                    case .success:
                        connectionChannel.connect(to: address, promise: promise)
                    case .failure(let error):
                        promise.fail(error)
                    }
                }
            }
        ).get()
    }

    /// Specify the `unixDomainSocket` path to connect to for the UDS `Channel` that will be established.
    ///
    /// - Parameters:
    ///   - unixDomainSocketPath: The _Unix domain socket_ path to connect to.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///     method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func connect<Output: Sendable>(
        unixDomainSocketPath: String,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> Output {
        let address = try SocketAddress(unixDomainSocketPath: unixDomainSocketPath)
        return try await self.connect(
            to: address,
            channelInitializer: channelInitializer
        )
    }

    /// Specify the `endpoint` to connect to for the TCP `Channel` that will be established.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint to connect to.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///     method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func connect<Output: Sendable>(
        endpoint: NWEndpoint,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> Output {
        try await self.connect0(
            channelInitializer: channelInitializer,
            registration: { connectionChannel, promise in
                connectionChannel.register().whenComplete { result in
                    switch result {
                    case .success:
                        connectionChannel.triggerUserOutboundEvent(
                            NIOTSNetworkEvents.ConnectToNWEndpoint(endpoint: endpoint),
                            promise: promise
                        )
                    case .failure(let error):
                        promise.fail(error)
                    }
                }
            }
        ).get()
    }

    /// Use a pre-existing `NWConnection` to connect a `Channel`.
    ///
    /// - Parameters:
    ///   - connection: The `NWConnection` to wrap.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///     method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func withExistingNWConnection<Output: Sendable>(
        _ connection: NWConnection,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> Output {
        try await self.connect0(
            existingNWConnection: connection,
            channelInitializer: channelInitializer,
            registration: { connectionChannel, promise in
                connectionChannel.registerAlreadyConfigured0(promise: promise)
            }
        ).get()
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    private func connect0<ChannelInitializerResult: Sendable>(
        existingNWConnection: NWConnection? = nil,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<ChannelInitializerResult>,
        registration: @Sendable @escaping (NIOTSConnectionChannel, EventLoopPromise<Void>) -> Void
    ) -> EventLoopFuture<ChannelInitializerResult> {
        let connectionChannel: NIOTSConnectionChannel
        if let newConnection = existingNWConnection {
            connectionChannel = NIOTSConnectionChannel(
                wrapping: newConnection,
                on: self.group.next() as! NIOTSEventLoop,
                tcpOptions: self.tcpOptions,
                tlsOptions: self.tlsOptions,
                nwParametersConfigurator: self.nwParametersConfigurator
            )
        } else {
            connectionChannel = NIOTSConnectionChannel(
                eventLoop: self.group.next() as! NIOTSEventLoop,
                qos: self.qos,
                tcpOptions: self.tcpOptions,
                tlsOptions: self.tlsOptions,
                nwParametersConfigurator: self.nwParametersConfigurator
            )
        }
        let initializer = self.channelInitializer
        let channelInitializer = { @Sendable (channel: Channel) -> EventLoopFuture<ChannelInitializerResult> in
            initializer(channel).flatMap { channelInitializer(channel) }
        }
        let channelOptions = self.channelOptions

        return connectionChannel.eventLoop.flatSubmit { [connectTimeout] in
            channelOptions.applyAllChannelOptions(to: connectionChannel).flatMap {
                channelInitializer(connectionChannel)
            }.flatMap { result -> EventLoopFuture<ChannelInitializerResult> in
                let connectPromise: EventLoopPromise<Void> = connectionChannel.eventLoop.makePromise()
                registration(connectionChannel, connectPromise)
                let cancelTask = connectionChannel.eventLoop.scheduleTask(in: connectTimeout) {
                    connectPromise.fail(ChannelError.connectTimeout(connectTimeout))
                    connectionChannel.close(promise: nil)
                }

                connectPromise.futureResult.whenComplete { (_: Result<Void, Error>) in
                    cancelTask.cancel()
                }
                return connectPromise.futureResult.map { result }
            }.flatMapErrorThrowing {
                connectionChannel.close(promise: nil)
                throw $0
            }
        }
    }
}

@available(*, unavailable)
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension NIOTSConnectionBootstrap: Sendable {}

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension NIOTSConnectionBootstrap: NIOClientTCPBootstrapProtocol {
    /// Apply any understood shorthand options to the bootstrap, removing them from the set of options if they are consumed.
    /// - parameters:
    ///     - options:  The options to try applying - the options applied should be consumed from here.
    /// - returns: The updated bootstrap with any understood options applied.
    public func _applyChannelConvenienceOptions(_ options: inout ChannelOptions.TCPConvenienceOptions) -> Self {
        var toReturn = self
        if options.consumeAllowLocalEndpointReuse().isSet {
            toReturn = self.channelOption(NIOTSChannelOptions.allowLocalEndpointReuse, value: true)
        }
        return toReturn
    }
}
#endif
