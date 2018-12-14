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


public final class NIOTSConnectionBootstrap {
    private let group: NIOTSEventLoopGroup
    private var channelInitializer: ((Channel) -> EventLoopFuture<Void>)?
    private var connectTimeout: TimeAmount = TimeAmount.seconds(10)
    private var channelOptions = ChannelOptionStorage()
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
    public func channelOption<T: ChannelOption>(_ option: T, value: T.OptionType) -> Self {
        channelOptions.put(key: option, value: value)
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
            return self.group.next().makeFailedFuture(error: NIOTSErrors.InvalidPort(port: port))
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
            return group.next().makeFailedFuture(error: error)
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
        let initializer = self.channelInitializer ?? { _ in conn.eventLoop.makeSucceededFuture(result: ()) }
        let channelOptions = self.channelOptions

        return conn.eventLoop.submit {
            return channelOptions.applyAll(channel: conn).then {
                initializer(conn)
                }.then {
                    conn.register()
                }.then {
                    let connectPromise: EventLoopPromise<Void> = conn.eventLoop.makePromise()
                    connectAction(conn, connectPromise)
                    let cancelTask = conn.eventLoop.scheduleTask(in: self.connectTimeout) {
                        connectPromise.fail(error: ChannelError.connectTimeout(self.connectTimeout))
                        conn.close(promise: nil)
                    }

                    connectPromise.futureResult.whenComplete { (_: Result<Void, Error>) in
                        cancelTask.cancel()
                    }
                    return connectPromise.futureResult
                }.map { conn }.thenIfErrorThrowing {
                    conn.close(promise: nil)
                    throw $0
            }
            }.then { $0 }
    }
}

internal struct ChannelOptionStorage {
    private var storage: [(Any, (Any, (Channel) -> (Any, Any) -> EventLoopFuture<Void>))] = []

    mutating func put<K: ChannelOption>(key: K,
                                        value newValue: K.OptionType) {
        func applier(_ t: Channel) -> (Any, Any) -> EventLoopFuture<Void> {
            return { (x, y) in
                return t.setOption(option: x as! K, value: y as! K.OptionType)
            }
        }
        var hasSet = false
        self.storage = self.storage.map { typeAndValue in
            let (type, value) = typeAndValue
            if type is K {
                hasSet = true
                return (key, (newValue, applier))
            } else {
                return (type, value)
            }
        }
        if !hasSet {
            self.storage.append((key, (newValue, applier)))
        }
    }

    func applyAll(channel: Channel) -> EventLoopFuture<Void> {
        let applyPromise: EventLoopPromise<Void> = channel.eventLoop.makePromise()
        var it = self.storage.makeIterator()

        func applyNext() {
            guard let (key, (value, applier)) = it.next() else {
                // If we reached the end, everything is applied.
                applyPromise.succeed(result: ())
                return
            }

            applier(channel)(key, value).map {
                applyNext()
                }.cascadeFailure(promise: applyPromise)
        }
        applyNext()

        return applyPromise.futureResult
    }
}
