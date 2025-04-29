//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2023 Apple Inc. and the SwiftNIO project authors
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

/// A ``NIOTSDatagramListenerBootstrap`` is an easy way to bootstrap a listener channel when creating network servers.
///
/// Example:
///
/// ```swift
///     let group = NIOTSEventLoopGroup()
///     defer {
///         try! group.syncShutdownGracefully()
///     }
///     let bootstrap = NIOTSDatagramListenerBootstrap(group: group)
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
/// The `EventLoopFuture` returned by `bind` will fire with a channel. This is the channel that owns the listening socket. Each
/// time it accepts a new connection it will fire a new child channel for the new connection through the `ChannelPipeline` via
/// `fireChannelRead`: as a result, the listening channel operates on `Channel`s as inbound messages. Outbound messages are
/// not supported on these listening channels, which means that each write attempt will fail.
///
/// Accepted channels operate on `ByteBuffer` as inbound data, and `IOData` as outbound data.
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
public final class NIOTSDatagramListenerBootstrap {
    private let group: EventLoopGroup
    private let childGroup: EventLoopGroup
    private var serverChannelInit: (@Sendable (Channel) -> EventLoopFuture<Void>)?
    private var childChannelInit: (@Sendable (Channel) -> EventLoopFuture<Void>)?
    private var serverChannelOptions = ChannelOptions.Storage()
    private var childChannelOptions = ChannelOptions.Storage()
    private var serverQoS: DispatchQoS?
    private var childQoS: DispatchQoS?
    private var udpOptions: NWProtocolUDP.Options = .init()
    private var childUDPOptions: NWProtocolUDP.Options = .init()
    private var tlsOptions: NWProtocolTLS.Options?
    private var childTLSOptions: NWProtocolTLS.Options?
    private var bindTimeout: TimeAmount?
    private var nwParametersConfigurator: (@Sendable (NWParameters) -> Void)?
    private var childNWParametersConfigurator: (@Sendable (NWParameters) -> Void)?

    /// Create a ``NIOTSDatagramListenerBootstrap`` for the `EventLoopGroup` `group`.
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
    ///     - group: The `EventLoopGroup` to use for the listening channel.
    public convenience init(group: EventLoopGroup) {
        self.init(group: group, childGroup: group)
    }

    /// Create a ``NIOTSDatagramListenerBootstrap`` for the ``NIOTSEventLoopGroup`` `group`.
    ///
    /// - parameters:
    ///     - group: The ``NIOTSEventLoopGroup`` to use for the listening channel.
    public convenience init(group: NIOTSEventLoopGroup) {
        self.init(group: group as EventLoopGroup)
    }

    /// Create a ``NIOTSDatagramListenerBootstrap``.
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
    ///     - group: The `EventLoopGroup` to use for the `bind` of the listening channel and to accept new child channels with.
    ///     - childGroup: The `EventLoopGroup` to run the accepted child channels on.
    public convenience init(group: EventLoopGroup, childGroup: EventLoopGroup) {
        guard NIOTSBootstraps.isCompatible(group: group) && NIOTSBootstraps.isCompatible(group: childGroup) else {
            preconditionFailure(
                "NIOTSListenerBootstrap is only compatible with NIOTSEventLoopGroup and "
                    + "NIOTSEventLoop. You tried constructing one with group: \(group) and "
                    + "childGroup: \(childGroup) at least one of which is incompatible."
            )
        }

        self.init(validatingGroup: group, childGroup: childGroup)!
    }

    /// Create a ``NIOTSDatagramListenerBootstrap`` on the `EventLoopGroup` `group` which accepts `Channel`s
    /// on `childGroup`, validating that the `EventLoopGroup`s are compatible with ``NIOTSDatagramListenerBootstrap``.
    ///
    /// - parameters:
    ///     - group: The `EventLoopGroup` to use for the `bind` of the listening channel and to accept new child channels with.
    ///     - childGroup: The `EventLoopGroup` to run the accepted child channels on.
    public init?(validatingGroup group: EventLoopGroup, childGroup: EventLoopGroup? = nil) {
        let childGroup = childGroup ?? group
        guard NIOTSBootstraps.isCompatible(group: group) && NIOTSBootstraps.isCompatible(group: childGroup) else {
            return nil
        }

        self.group = group
        self.childGroup = childGroup
    }

    /// Create a ``NIOTSDatagramListenerBootstrap``.
    ///
    /// - parameters:
    ///     - group: The ``NIOTSEventLoopGroup`` to use for the `bind` of the listening channel and to accept new child
    ///     channels with.
    ///     - childGroup: The ``NIOTSEventLoopGroup`` to run the accepted child channels on.
    public convenience init(group: NIOTSEventLoopGroup, childGroup: NIOTSEventLoopGroup) {
        self.init(group: group as EventLoopGroup, childGroup: childGroup as EventLoopGroup)
    }

    /// Initialize the listening channel with `initializer`. The most common task in initializer is to add
    /// `ChannelHandler`s to the `ChannelPipeline`.
    ///
    /// The listening channel uses the accepted child channels as inbound messages.
    ///
    /// > Note: To set the initializer for the accepted child channels, look at ``childChannelInitializer(_:)``.
    ///
    /// - parameters:
    ///     - initializer: A closure that initializes the provided `Channel`.
    @preconcurrency
    public func serverChannelInitializer(_ initializer: @Sendable @escaping (Channel) -> EventLoopFuture<Void>) -> Self
    {
        self.serverChannelInit = initializer
        return self
    }

    /// Initialize the accepted child channels with `initializer`. The most common task in initializer is to add
    /// `ChannelHandler`s to the `ChannelPipeline`. Note that if the `initializer` fails then the error will be
    /// fired in the *parent* channel.
    ///
    /// The accepted `Channel` will operate on `ByteBuffer` as inbound and `IOData` as outbound messages.
    ///
    /// - parameters:
    ///     - initializer: A closure that initializes the provided `Channel`.
    @preconcurrency
    public func childChannelInitializer(_ initializer: @Sendable @escaping (Channel) -> EventLoopFuture<Void>) -> Self {
        self.childChannelInit = initializer
        return self
    }

    /// Specifies a `ChannelOption` to be applied to the listening channel.
    ///
    /// > Note: To specify options for the accepted child channels, look at ``childChannelOption(_:value:)``.
    ///
    /// - parameters:
    ///     - option: The option to be applied.
    ///     - value: The value for the option.
    public func serverChannelOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> Self {
        self.serverChannelOptions.append(key: option, value: value)
        return self
    }

    /// Specifies a `ChannelOption` to be applied to the accepted child channels.
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

    /// Specifies the TCP options to use on the listener.
    public func udpOptions(_ options: NWProtocolUDP.Options) -> Self {
        self.udpOptions = options
        return self
    }

    /// Specifies the TCP options to use on the child `Channel`s.
    public func childUDPOptions(_ options: NWProtocolUDP.Options) -> Self {
        self.childUDPOptions = options
        return self
    }

    /// Specifies the TLS options to use on the listener.
    public func tlsOptions(_ options: NWProtocolTLS.Options) -> Self {
        self.tlsOptions = options
        return self
    }

    /// Specifies the TLS options to use on the child `Channel`s.
    public func childTLSOptions(_ options: NWProtocolTLS.Options) -> Self {
        self.childTLSOptions = options
        return self
    }

    /// Customise the `NWParameters` to be used when creating the `NWConnection` for the listener.
    public func configureNWParameters(
        _ configurator: @Sendable @escaping (NWParameters) -> Void
    ) -> Self {
        self.nwParametersConfigurator = configurator
        return self
    }

    /// Customise the `NWParameters` to be used when creating the `NWConnection`s for the child `Channel`s.
    public func configureChildNWParameters(
        _ configurator: @Sendable @escaping (NWParameters) -> Void
    ) -> Self {
        self.childNWParametersConfigurator = configurator
        return self
    }

    /// Bind the listening channel to `host` and `port`.
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

    /// Bind the listening channel to `address`.
    ///
    /// - parameters:
    ///     - address: The `SocketAddress` to bind on.
    public func bind(to address: SocketAddress) -> EventLoopFuture<Channel> {
        self.bind0(shouldRegister: true) { (channel, promise) in
            channel.bind(to: address, promise: promise)
        }
    }

    /// Bind the listening channel to a UNIX Domain Socket.
    ///
    /// - parameters:
    ///     - unixDomainSocketPath: The _Unix domain socket_ path to bind to. `unixDomainSocketPath` must not exist, it will be created by the system.
    public func bind(unixDomainSocketPath: String) -> EventLoopFuture<Channel> {
        self.bind0(shouldRegister: true) { (channel, promise) in
            do {
                let address = try SocketAddress(unixDomainSocketPath: unixDomainSocketPath)
                channel.bind(to: address, promise: promise)
            } catch {
                promise.fail(error)
            }
        }
    }

    /// Bind the listening channel to a given `NWEndpoint`.
    ///
    /// - parameters:
    ///     - endpoint: The `NWEndpoint` to bind this channel to.
    public func bind(endpoint: NWEndpoint) -> EventLoopFuture<Channel> {
        self.bind0(shouldRegister: true) { (channel, promise) in
            channel.triggerUserOutboundEvent(NIOTSNetworkEvents.BindToNWEndpoint(endpoint: endpoint), promise: promise)
        }
    }

    /// Bind the listening channel to an existing `NWListener`.
    ///
    /// - parameters:
    ///     - listener: The NWListener to wrap.
    public func withNWListener(_ listener: NWListener) -> EventLoopFuture<Channel> {
        self.bind0(existingNWListener: listener, shouldRegister: false) { channel, promise in
            channel.registerAlreadyConfigured0(promise: promise)
        }
    }

    private func bind0(
        existingNWListener: NWListener? = nil,
        shouldRegister: Bool,
        _ binder: @Sendable @escaping (NIOTSDatagramListenerChannel, EventLoopPromise<Void>) -> Void
    ) -> EventLoopFuture<Channel> {
        let eventLoop = self.group.next() as! NIOTSEventLoop
        let serverChannelInit =
            self.serverChannelInit ?? {
                @Sendable _ in eventLoop.makeSucceededFuture(())
            }
        let childChannelInit = self.childChannelInit
        let serverChannelOptions = self.serverChannelOptions
        let childChannelOptions = self.childChannelOptions

        let serverChannel: NIOTSDatagramListenerChannel
        if let newListener = existingNWListener {
            serverChannel = NIOTSDatagramListenerChannel(
                wrapping: newListener,
                on: eventLoop,
                qos: self.serverQoS,
                udpOptions: self.udpOptions,
                tlsOptions: self.tlsOptions,
                nwParametersConfigurator: self.nwParametersConfigurator,
                childLoopGroup: self.childGroup,
                childChannelQoS: self.childQoS,
                childUDPOptions: self.childUDPOptions,
                childTLSOptions: self.childTLSOptions,
                childNWParametersConfigurator: self.childNWParametersConfigurator
            )
        } else {
            serverChannel = NIOTSDatagramListenerChannel(
                eventLoop: eventLoop,
                qos: self.serverQoS,
                udpOptions: self.udpOptions,
                tlsOptions: self.tlsOptions,
                nwParametersConfigurator: self.nwParametersConfigurator,
                childLoopGroup: self.childGroup,
                childChannelQoS: self.childQoS,
                childUDPOptions: self.childUDPOptions,
                childTLSOptions: self.childTLSOptions,
                childNWParametersConfigurator: self.childNWParametersConfigurator
            )
        }

        return eventLoop.submit { [bindTimeout] in
            serverChannelOptions.applyAllChannelOptions(to: serverChannel).flatMap {
                serverChannelInit(serverChannel)
            }.flatMap {
                eventLoop.assertInEventLoop()
                return eventLoop.makeCompletedFuture {
                    try serverChannel.pipeline.syncOperations.addHandler(
                        AcceptHandler<NIOTSDatagramConnectionChannel>(
                            childChannelInitializer: childChannelInit,
                            childChannelOptions: childChannelOptions
                        )
                    )
                }
            }.flatMap {
                if shouldRegister {
                    return serverChannel.register()
                } else {
                    return eventLoop.makeSucceededVoidFuture()
                }
            }.flatMap {
                let bindPromise = eventLoop.makePromise(of: Void.self)
                binder(serverChannel, bindPromise)

                if let bindTimeout = bindTimeout {
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

@available(*, unavailable)
extension NIOTSDatagramListenerBootstrap: Sendable {}
#endif
