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
public final class NIOTSConnectionBootstrap {
    private let group: NIOTSEventLoopGroup
    private var channelInitializer: ((Channel) -> EventLoopFuture<Void>)?
    private var connectTimeout: TimeAmount = TimeAmount.seconds(10)
    private var channelOptions = ChannelOptionsStorage()
    private var qos: DispatchQoS?
    private var tcpOptions: NWProtocolTCP.Options = .init()
    private var tlsOptions: NWProtocolTLS.Options?

    /// Create a `NIOTSConnectionBootstrap` on the `NIOTSEventLoopGroup` `group`.
    ///
    /// - parameters:
    ///     - group: The `NIOTSEventLoopGroup` to use.
    public init(group: NIOTSEventLoopGroup) {
        self.group = group
    }

    /// Initialize the connected `NIOTSConnectionChannel` with `initializer`. The most common task in initializer is to add
    /// `ChannelHandler`s to the `ChannelPipeline`.
    ///
    /// The connected `Channel` will operate on `ByteBuffer` as inbound and `IOData` as outbound messages.
    ///
    /// - parameters:
    ///     - handler: A closure that initializes the provided `Channel`.
    public func channelInitializer(_ handler: @escaping (Channel) -> EventLoopFuture<Void>) -> Self {
        self.channelInitializer = handler
        return self
    }

    /// Specifies a `ChannelOption` to be applied to the `NIOTSConnectionChannel`.
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
    ///
    /// To retrieve the TCP options from connected channels, use
    /// `NIOTSChannelOptions.TCPConfiguration`. It is not possible to change the
    /// TCP configuration after `connect` is called.
    public func tcpOptions(_ options: NWProtocolTCP.Options) -> Self {
        self.tcpOptions = options
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

    /// Specify the `host` and `port` to connect to for the TCP `Channel` that will be established.
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

    /// Specify the `address` to connect to for the TCP `Channel` that will be established.
    ///
    /// - parameters:
    ///     - address: The address to connect to.
    /// - returns: An `EventLoopFuture<Channel>` to deliver the `Channel` when connected.
    public func connect(to address: SocketAddress) -> EventLoopFuture<Channel> {
        return self.connect { channel, promise in
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
        return self.connect { channel, promise in
            channel.triggerUserOutboundEvent(NIOTSNetworkEvents.ConnectToNWEndpoint(endpoint: endpoint),
                                             promise: promise)
        }
    }

    private func connect(_ connectAction: @escaping (Channel, EventLoopPromise<Void>) -> Void) -> EventLoopFuture<Channel> {
        let conn: Channel = NIOTSConnectionChannel(eventLoop: self.group.next() as! NIOTSEventLoop,
                                                   qos: self.qos,
                                                   tcpOptions: self.tcpOptions,
                                                   tlsOptions: self.tlsOptions)
        let initializer = self.channelInitializer ?? { _ in conn.eventLoop.makeSucceededFuture(()) }
        let channelOptions = self.channelOptions

        return conn.eventLoop.submit {
            return channelOptions.applyAllChannelOptions(to: conn).flatMap {
                initializer(conn)
            }.flatMap {
                conn.register()
            }.flatMap {
                let connectPromise: EventLoopPromise<Void> = conn.eventLoop.makePromise()
                connectAction(conn, connectPromise)
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

// This is a backport of ChannelOptions.Storage from SwiftNIO because the initializer wasn't public, so we couldn't actually build it.
// When https://github.com/apple/swift-nio/pull/988 is in a shipped release, we can remove this and simply bump our lowest supported version of SwiftNIO.
@available(OSX 10.14, iOS 12.0, tvOS 12.0, *)
internal struct ChannelOptionsStorage {
    internal var _storage: [(Any, (Any, (Channel) -> (Any, Any) -> EventLoopFuture<Void>))] = []

    internal init() { }

    /// Add `Options`, a `ChannelOption` to the `ChannelOptionsStorage`.
    ///
    /// - parameters:
    ///    - key: the key for the option
    ///    - value: the value for the option
    internal mutating func append<Option: ChannelOption>(key newKey: Option, value newValue: Option.Value) {
        func applier(_ t: Channel) -> (Any, Any) -> EventLoopFuture<Void> {
            return { (option, value) in
                return t.setOption(option as! Option, value: value as! Option.Value)
            }
        }
        var hasSet = false
        self._storage = self._storage.map { currentKeyAndValue in
            let (currentKey, _) = currentKeyAndValue
            if let currentKey = currentKey as? Option, currentKey == newKey {
                hasSet = true
                return (currentKey, (newValue, applier))
            } else {
                return currentKeyAndValue
            }
        }
        if !hasSet {
            self._storage.append((newKey, (newValue, applier)))
        }
    }

    /// Apply all stored `ChannelOption`s to `Channel`.
    ///
    /// - parameters:
    ///    - channel: The `Channel` to apply the `ChannelOption`s to
    /// - returns:
    ///    - An `EventLoopFuture` that is fulfilled when all `ChannelOption`s have been applied to the `Channel`.
    public func applyAllChannelOptions(to channel: Channel) -> EventLoopFuture<Void> {
        let applyPromise = channel.eventLoop.makePromise(of: Void.self)
        var it = self._storage.makeIterator()

        func applyNext() {
            guard let (key, (value, applier)) = it.next() else {
                // If we reached the end, everything is applied.
                applyPromise.succeed(())
                return
            }

            applier(channel)(key, value).map {
                applyNext()
                }.cascadeFailure(to: applyPromise)
        }
        applyNext()

        return applyPromise.futureResult
    }
}
#endif
