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
import Atomics
import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOFoundationCompat
import NIOTLS
import Dispatch
import Network
import Security

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
internal final class NIOTSDatagramChannel: StateManagedNWConnectionChannel {
    typealias ActiveSubstate = UDPSubstate

    enum UDPSubstate: NWConnectionSubstate {
        case open, closed
        
        init() {
            self = .open
        }
        
        static func closeInput(state: inout ChannelState<NIOTSDatagramChannel.UDPSubstate>) throws {
            throw NIOTSErrors.InvalidChannelStateTransition()
        }
        
        static func closeOutput(state: inout ChannelState<NIOTSDatagramChannel.UDPSubstate>) throws {
            throw NIOTSErrors.InvalidChannelStateTransition()
        }
    }

    /// The kinds of channel activation this channel supports
    internal let supportedActivationType: ActivationType = .connect
    
    /// The `ByteBufferAllocator` for this `Channel`.
    public let allocator = ByteBufferAllocator()

    /// An `EventLoopFuture` that will complete when this channel is finally closed.
    public var closeFuture: EventLoopFuture<Void> {
        return self.closePromise.futureResult
    }

    /// The parent `Channel` for this one, if any.
    public let parent: Channel?

    /// The `EventLoop` this `Channel` belongs to.
    internal let tsEventLoop: NIOTSEventLoop

    private(set) var _pipeline: ChannelPipeline! = nil  // this is really a constant (set in .init) but needs `self` to be constructed and therefore a `var`. Do not change as this needs to accessed from arbitrary threads.

    internal let closePromise: EventLoopPromise<Void>

    /// The underlying `NWConnection` that this `Channel` wraps. This is only non-nil
    /// after the initial connection attempt has been made.
    internal var connection: NWConnection?

    /// The `DispatchQueue` that socket events for this connection will be dispatched onto.
    internal let connectionQueue: DispatchQueue

    /// An `EventLoopPromise` that will be succeeded or failed when a connection attempt succeeds or fails.
    internal var connectPromise: EventLoopPromise<Void>?

    /// The UDP options for this connection.
    private var udpOptions: NWProtocolUDP.Options

    internal var nwOptions: NWProtocolUDP.Options { udpOptions }

    /// The TLS options for this connection, if any.
    private var tlsOptions: NWProtocolTLS.Options?

    /// The state of this connection channel.
    internal var state: ChannelState<ActiveSubstate> = .idle

    /// The active state, used for safely reporting the channel state across threads.
    internal var isActive0 = ManagedAtomic(false)

    /// Whether a call to NWConnection.receive has been made, but the completion
    /// handler has not yet been invoked.
    internal var outstandingRead: Bool = false

    /// The options for this channel.
    internal var options = TransportServicesChannelOptions()

    /// Any pending writes that have yet to be delivered to the network stack.
    internal var _pendingWrites = CircularBuffer<PendingWrite>(initialCapacity: 8)

    /// An object to keep track of pending writes and manage our backpressure signaling.
    internal var _backpressureManager = BackpressureManager()

    /// The value of SO_REUSEADDR.
    internal var reuseAddress = false

    /// The value of SO_REUSEPORT.
    internal var reusePort = false

    /// Whether to use peer-to-peer connectivity when connecting to Bonjour services.
    internal var enablePeerToPeer = false

    /// The cache of the local and remote socket addresses. Must be accessed using _addressCacheLock.
    private var _addressCache = AddressCache(local: nil, remote: nil)

    internal var addressCache: AddressCache {
        get {
            return self._addressCacheLock.withLock {
                return self._addressCache
            }
        }
        set {
            return self._addressCacheLock.withLock {
                self._addressCache = newValue
            }
        }
    }

    /// A lock that guards the _addressCache.
    private let _addressCacheLock = NIOLock()

    internal var allowLocalEndpointReuse = false
    internal var multipathServiceType: NWParameters.MultipathServiceType = .disabled
    
    var parameters: NWParameters {
        NWParameters(dtls: self.tlsOptions, udp: self.udpOptions)
    }
    
    var _inboundStreamOpen: Bool {
        switch self.state {
        case .active(.open):
            return true
        case .idle, .registered, .activating, .active, .inactive:
            return false
        }
    }

    func setChannelSpecificOption0<Option>(option: Option, value: Option.Value) throws where Option : NIOCore.ChannelOption {
        fatalError("option \(type(of: option)).\(option) not supported")
    }

    func getChannelSpecificOption0<Option>(option: Option) throws -> Option.Value where Option : ChannelOption {
        fatalError("option \(type(of: option)).\(option) not supported")
    }

    /// Create a `NIOTSDatagramConnectionChannel` on a given `NIOTSEventLoop`.
    ///
    /// Note that `NIOTSDatagramConnectionChannel` objects cannot be created on arbitrary loops types.
    internal init(eventLoop: NIOTSEventLoop,
                  parent: Channel? = nil,
                  qos: DispatchQoS? = nil,
                  udpOptions: NWProtocolUDP.Options,
                  tlsOptions: NWProtocolTLS.Options?) {
        self.tsEventLoop = eventLoop
        self.closePromise = eventLoop.makePromise()
        self.parent = parent
        self.connectionQueue = eventLoop.channelQueue(label: "nio.nioTransportServices.connectionchannel", qos: qos)
        self.udpOptions = udpOptions
        self.tlsOptions = tlsOptions

        // Must come last, as it requires self to be completely initialized.
        self._pipeline = ChannelPipeline(channel: self)
    }

    /// Create a `NIOTSDatagramConnectionChannel` with an already-established `NWConnection`.
    internal convenience init(wrapping connection: NWConnection,
                              on eventLoop: NIOTSEventLoop,
                              parent: Channel,
                              qos: DispatchQoS? = nil,
                              udpOptions: NWProtocolUDP.Options,
                              tlsOptions: NWProtocolTLS.Options?) {
        self.init(eventLoop: eventLoop,
                  parent: parent,
                  qos: qos,
                  udpOptions: udpOptions,
                  tlsOptions: tlsOptions)
        self.connection = connection
    }
}
#endif
