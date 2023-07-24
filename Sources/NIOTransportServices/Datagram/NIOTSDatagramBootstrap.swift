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
import NIOCore
import Dispatch
import Network

/// A `NIOTSDatagramBootstrap` is an easy way to bootstrap a `NIOTSDatagramChannel` when creating network clients.
///
/// Usually you re-use a `NIOTSDatagramBootstrap` once you set it up, calling `connect` multiple times on the same bootstrap.
/// This way you ensure that the same `EventLoop`s will be shared across all your connections.
///
/// Example:
///
/// ```swift
///     let group = NIOTSEventLoopGroup()
///     defer {
///         try! group.syncShutdownGracefully()
///     }
///     let bootstrap = NIOTSDatagramBootstrap(group: group)
///         .channelInitializer { channel in
///             channel.pipeline.addHandler(MyChannelHandler())
///         }
///     try! bootstrap.connect(host: "example.org", port: 12345).wait()
///     /* the Channel is now connected */
/// ```
///
/// The connected `NIOTSDatagramChannel` will operate on `ByteBuffer` as inbound and outbound messages.
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
public final class NIOTSDatagramBootstrap {
    private let group: EventLoopGroup
    private var channelInitializer: ((Channel) -> EventLoopFuture<Void>)?
    private var connectTimeout: TimeAmount = TimeAmount.seconds(10)
    private var channelOptions = ChannelOptions.Storage()
    private var qos: DispatchQoS?
    private var udpOptions: NWProtocolUDP.Options = .init()
    private var tlsOptions: NWProtocolTLS.Options?

    /// Create a `NIOTSDatagramConnectionBootstrap` on the `EventLoopGroup` `group`.
    ///
    /// This initializer only exists to be more in-line with the NIO core bootstraps, in that they
    /// may be constructed with an `EventLoopGroup` and by extension an `EventLoop`. As such an
    /// existing `NIOTSEventLoop` may be used to initialize this bootstrap. Where possible the
    /// initializers accepting `NIOTSEventLoopGroup` should be used instead to avoid the wrong
    /// type being used.
    ///
    /// Note that the "real" solution is described in https://github.com/apple/swift-nio/issues/674.
    ///
    /// - parameters:
    ///     - group: The `EventLoopGroup` to use.
    public init(group: EventLoopGroup) {
        self.group = group
    }

    /// Create a `NIOTSDatagramConnectionBootstrap` on the `NIOTSEventLoopGroup` `group`.
    ///
    /// - parameters:
    ///     - group: The `NIOTSEventLoopGroup` to use.
    public convenience init(group: NIOTSEventLoopGroup) {
      self.init(group: group as EventLoopGroup)
    }

    /// Initialize the connected `NIOTSDatagramConnectionChannel` with `initializer`. The most common task in initializer is to add
    /// `ChannelHandler`s to the `ChannelPipeline`.
    ///
    /// The connected `Channel` will operate on `ByteBuffer` as inbound and outbound messages.
    ///
    /// - parameters:
    ///     - handler: A closure that initializes the provided `Channel`.
    public func channelInitializer(_ handler: @escaping (Channel) -> EventLoopFuture<Void>) -> Self {
        self.channelInitializer = handler
        return self
    }

    /// Specifies a `ChannelOption` to be applied to the `NIOTSDatagramConnectionChannel`.
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

    /// Specifies the UDP options to use on the `Channel`s.
    ///
    /// To retrieve the UDP options from connected channels, use
    /// `NIOTSChannelOptions.UDPConfiguration`. It is not possible to change the
    /// UDP configuration after `connect` is called.
    public func udpOptions(_ options: NWProtocolUDP.Options) -> Self {
        self.udpOptions = options
        return self
    }

    /// Specifies the TLS options to use on the `Channel`s.
    ///
    /// To retrieve the TLS options from connected channels, use
    /// `NIOTSChannelOptions.TLSConfiguration`. It is not possible to change the
    /// TLS configuration after `connect` is called.
    public func tlsOptions(_ options: NWProtocolTLS.Options) -> Self {
        self.tlsOptions = options
        return self
    }

    /// Specify the `host` and `port` to connect to for the UDP `Channel` that will be established.
    ///
    /// - parameters:
    ///     - host: The host to connect to.
    ///     - port: The port to connect to.
    /// - returns: An `EventLoopFuture<Channel>` to deliver the `Channel` when connected.
    public func connect(host: String, port: Int) -> EventLoopFuture<Channel> {
        guard let actualPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return self.group.next().makeFailedFuture(NIOTSErrors.InvalidPort(port: port))
        }
        return self.connect(endpoint: NWEndpoint.hostPort(host: .init(host), port: actualPort))
    }

    /// Specify the `address` to connect to for the UDP `Channel` that will be established.
    ///
    /// - parameters:
    ///     - address: The address to connect to.
    /// - returns: An `EventLoopFuture<Channel>` to deliver the `Channel` when connected.
    public func connect(to address: SocketAddress) -> EventLoopFuture<Channel> {
        return self.connect0 { channel, promise in
            channel.bind(to: address, promise: promise)
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

    /// Specify the `endpoint` to connect to for the UDP `Channel` that will be established.
    public func connect(endpoint: NWEndpoint) -> EventLoopFuture<Channel> {
        return self.connect0 { channel, promise in
            channel.triggerUserOutboundEvent(
                NIOTSNetworkEvents.ConnectToNWEndpoint(endpoint: endpoint),
                promise: promise
            )
        }
    }

    private func connect0(_ binder: @escaping (Channel, EventLoopPromise<Void>) -> Void) -> EventLoopFuture<Channel> {
        let conn: Channel = NIOTSDatagramChannel(eventLoop: self.group.next() as! NIOTSEventLoop,
                                                   qos: self.qos,
                                                   udpOptions: self.udpOptions,
                                                   tlsOptions: self.tlsOptions)
        let initializer = self.channelInitializer ?? { _ in conn.eventLoop.makeSucceededFuture(()) }
        let channelOptions = self.channelOptions

        return conn.eventLoop.submit {
            return channelOptions.applyAllChannelOptions(to: conn).flatMap {
                initializer(conn)
            }.flatMap {
                conn.eventLoop.assertInEventLoop()
                return conn.register()
            }.flatMap {
                let connectPromise: EventLoopPromise<Void> = conn.eventLoop.makePromise()
                binder(conn, connectPromise)
                let cancelTask = conn.eventLoop.scheduleTask(in: self.connectTimeout) {
                    connectPromise.fail(ChannelError.connectTimeout(self.connectTimeout))
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
        }.flatMap { $0 }
    }
}
#endif
