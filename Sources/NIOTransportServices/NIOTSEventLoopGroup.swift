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
import Foundation
import NIOCore
import NIOConcurrencyHelpers
import Dispatch
import Network
import Atomics

/// An `EventLoopGroup` containing `EventLoop`s specifically designed for use with
/// Network.framework's post-sockets networking API.
///
/// These `EventLoop`s provide highly optimised and powerful networking tools for
/// the Darwin platforms. They have a number of advantages over the regular
/// `SelectableEventLoop` that NIO uses on other platforms. In particular:
///
/// - The use of `DispatchQueue`s to schedule tasks allows the Darwin kernels to make
///     intelligent scheduling decisions, as well as to maintain QoS and ensure that
///     tasks required to handle networking in your application are given appropriate
///     priority by the system.
/// - Network.framework provides powerful tools for observing network state and managing
///     connections on devices with highly fluid networking environments, such as laptops
///     and mobile devices. These tools can be exposed to `Channel`s using this backend.
/// - Network.framework brings the networking stack into userspace, reducing the overhead
///     of most network operations by removing syscalls, and greatly increasing the safety
///     and security of the network stack.
/// - The applications networking needs are more effectively communicated to the kernel,
///     allowing mobile devices to change radio configuration and behaviour as needed to
///     take advantage of the various interfaces available on mobile devices.
///
/// In general, when building applications whose primary purpose is to be deployed on Darwin
/// platforms, the ``NIOTSEventLoopGroup`` should be preferred over the
/// `MultiThreadedEventLoopGroup`. In particular, on iOS, the ``NIOTSEventLoopGroup`` is the
/// preferred networking backend.
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
public final class NIOTSEventLoopGroup: EventLoopGroup {
    private let index = ManagedAtomic(0)
    private let eventLoops: [NIOTSEventLoop]
    private let canBeShutDown: Bool

    private init(eventLoops: [NIOTSEventLoop], canBeShutDown: Bool) {
        self.eventLoops = eventLoops
        self.canBeShutDown = canBeShutDown
    }

    /// Construct a ``NIOTSEventLoopGroup`` with a specified number of loops and QoS.
    ///
    /// - parameters:
    ///     - loopCount: The number of independent loops to use. Defaults to `1`.
    ///     - defaultQoS: The default QoS for tasks enqueued on this loop. Defaults to `.default`.
    public convenience init(loopCount: Int = 1, defaultQoS: DispatchQoS = .default) {
        self.init(loopCount: loopCount, defaultQoS: defaultQoS, canBeShutDown: true)
    }

    internal convenience init(loopCount: Int, defaultQoS: DispatchQoS, canBeShutDown: Bool) {
        precondition(loopCount > 0)
        let eventLoops = (0..<loopCount).map { _ in
            NIOTSEventLoop(qos: defaultQoS, canBeShutDownIndividually: false)
        }
        self.init(eventLoops: eventLoops, canBeShutDown: canBeShutDown)
    }

    public static func _makePerpetualGroup(loopCount: Int, defaultQoS: DispatchQoS) -> Self {
        self.init(loopCount: loopCount, defaultQoS: defaultQoS, canBeShutDown: false)
    }

    public func next() -> EventLoop {
        self.eventLoops[abs(index.loadThenWrappingIncrement(ordering: .relaxed) % self.eventLoops.count)]
    }

    /// Shuts down all of the event loops, rendering them unable to perform further work.
    @preconcurrency
    public func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping @Sendable (Error?) -> Void) {
        guard self.canBeShutDown else {
            queue.async {
                callback(EventLoopError.unsupportedOperation)
            }
            return
        }
        let g = DispatchGroup()
        let q = DispatchQueue(label: "nio.transportservices.shutdowngracefullyqueue", target: queue)
        let error: NIOLockedValueBox<Error?> = .init(nil)

        for loop in self.eventLoops {
            g.enter()
            loop.closeGently().recover { err in
                q.sync { error.withLockedValue({ $0 = err }) }
            }.whenComplete { (_: Result<Void, Error>) in
                g.leave()
            }
        }

        g.notify(queue: q) {
            callback(error.withLockedValue({ $0 }))
        }
    }

    public func makeIterator() -> EventLoopIterator {
        EventLoopIterator(self.eventLoops)
    }
}

/// A TLS provider to bootstrap TLS-enabled connections with `NIOClientTCPBootstrap`.
///
/// Example:
///
///     // Creating the "universal bootstrap" with the `NIOTSClientTLSProvider`.
///     let tlsProvider = NIOTSClientTLSProvider()
///     let bootstrap = NIOClientTCPBootstrap(NIOTSConnectionBootstrap(group: group), tls: tlsProvider)
///
///     // Bootstrapping a connection using the "universal bootstrapping mechanism"
///     let connection = bootstrap.enableTLS()
///                          .connect(host: "example.com", port: 443)
///                          .wait()
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
public struct NIOTSClientTLSProvider: NIOClientTLSProvider {
    public typealias Bootstrap = NIOTSConnectionBootstrap

    let tlsOptions: NWProtocolTLS.Options

    /// Construct the TLS provider.
    public init(tlsOptions: NWProtocolTLS.Options = NWProtocolTLS.Options()) {
        self.tlsOptions = tlsOptions
    }

    /// Enable TLS on the bootstrap. This is not a function you will typically call as a user, it is called by
    /// `NIOClientTCPBootstrap`.
    public func enableTLS(_ bootstrap: NIOTSConnectionBootstrap) -> NIOTSConnectionBootstrap {
        bootstrap.tlsOptions(self.tlsOptions)
    }
}

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension NIOTSEventLoopGroup: @unchecked Sendable {}

@available(*, unavailable)
extension NIOTSClientTLSProvider: Sendable {}

#endif
