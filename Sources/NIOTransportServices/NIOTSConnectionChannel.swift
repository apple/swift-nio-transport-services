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
import Foundation
import NIOCore
import NIOConcurrencyHelpers
import NIOFoundationCompat
import NIOTLS
import Dispatch
import Network
import Security
import Atomics

/// Channel options for the connection channel.
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
struct TransportServicesChannelOptions {
    /// Whether autoRead is enabled for this channel.
    internal var autoRead: Bool = true

    /// Whether we support remote half closure. If not true, remote half closure will
    /// cause connection drops.
    internal var supportRemoteHalfClosure: Bool = false

    /// Whether this channel should wait for the connection to become active.
    internal var waitForActivity: Bool = true
}

internal struct AddressCache {
    // deliberately lets because they must always be updated together (so forcing `init` is useful).
    let local: SocketAddress?
    let remote: SocketAddress?

    init(local: SocketAddress?, remote: SocketAddress?) {
        self.local = local
        self.remote = remote
    }
}

/// A structure that manages backpressure signaling on this channel.
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
internal struct BackpressureManager {
    /// Whether the channel is writable, given the current watermark state.
    ///
    /// This is an atomic only because the channel writability flag needs to be safe to access from multiple
    /// threads. All activity in this structure itself is expected to be thread-safe.
    ///
    /// All code that operates on this atomic uses load/store, not compareAndSwap. This is because we know
    /// that this atomic is only ever written from one thread: the event loop thread. All unsynchronized
    /// access is only reading. As a result, we don't have racing writes, and don't need CAS. This is good,
    /// because in most cases these loads/stores will be free, as the user will never actually check the
    /// channel writability from another thread, meaning this cache line is uncontended. CAS is never free:
    /// it always has some substantial runtime cost over loads/stores.
    let writable = ManagedAtomic(true)

    /// The number of bytes outstanding on the network.
    private var outstandingBytes: Int = 0

    /// The watermarks currently configured by the user.
    private(set) var waterMarks = ChannelOptions.Types.WriteBufferWaterMark(low: 32 * 1024, high: 64 * 1024)

    /// Adds `newBytes` to the queue of outstanding bytes, and returns whether this
    /// has caused a writability change.
    ///
    /// - parameters:
    ///     - newBytes: the number of bytes queued to send, but not yet sent.
    /// - returns: Whether the state changed.
    mutating func writabilityChanges(whenQueueingBytes newBytes: Int) -> Bool {
        self.outstandingBytes += newBytes
        if self.outstandingBytes > self.waterMarks.high && self.writable.load(ordering: .relaxed) {
            self.writable.store(false, ordering: .relaxed)
            return true
        }

        return false
    }

    /// Removes `sentBytes` from the queue of outstanding bytes, and returns whether this
    /// has caused a writability change.
    ///
    /// - parameters:
    ///     - newBytes: the number of bytes sent to the network.
    /// - returns: Whether the state changed.
    mutating func writabilityChanges(whenBytesSent sentBytes: Int) -> Bool {
        self.outstandingBytes -= sentBytes
        if self.outstandingBytes < self.waterMarks.low && !self.writable.load(ordering: .relaxed) {
            self.writable.store(true, ordering: .relaxed)
            return true
        }

        return false
    }

    /// Updates the watermarks to `waterMarks`, and returns whether this change has changed the
    /// writability state of the channel.
    ///
    /// - parameters:
    ///     - waterMarks: The new waterMarks to use.
    /// - returns: Whether the state changed.
    mutating func writabilityChanges(
        whenUpdatingWaterMarks waterMarks: ChannelOptions.Types.WriteBufferWaterMark
    ) -> Bool {
        let writable = self.writable.load(ordering: .relaxed)
        self.waterMarks = waterMarks

        if writable && self.outstandingBytes > self.waterMarks.high {
            self.writable.store(false, ordering: .relaxed)
            return true
        } else if !writable && self.outstandingBytes < self.waterMarks.low {
            self.writable.store(true, ordering: .relaxed)
            return true
        }

        return false
    }
}

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
internal final class NIOTSConnectionChannel: StateManagedNWConnectionChannel {
    /// The `ByteBufferAllocator` for this `Channel`.
    public let allocator = ByteBufferAllocator()

    /// An `EventLoopFuture` that will complete when this channel is finally closed.
    public var closeFuture: EventLoopFuture<Void> {
        self.closePromise.futureResult
    }

    /// The parent `Channel` for this one, if any.
    public let parent: Channel?

    /// The `EventLoop` this `Channel` belongs to.
    internal let tsEventLoop: NIOTSEventLoop

    // This is really a constant (set in .init) but needs `self` to be constructed and therefore a `var`.
    // *Do not change* as this needs to accessed from arbitrary threads.
    private(set) var _pipeline: ChannelPipeline! = nil

    internal let closePromise: EventLoopPromise<Void>

    /// The underlying `NWConnection` that this `Channel` wraps. This is only non-nil
    /// after the initial connection attempt has been made.
    internal var connection: NWConnection?

    /// The minimum length of data to receive from this connection, until the content is complete.
    internal var minimumIncompleteReceiveLength: Int

    /// The maximum length of data to receive from this connection in a single completion.
    internal var maximumReceiveLength: Int

    /// The `DispatchQueue` that socket events for this connection will be dispatched onto.
    internal let connectionQueue: DispatchQueue

    /// An `EventLoopPromise` that will be succeeded or failed when a connection attempt succeeds or fails.
    internal var connectPromise: EventLoopPromise<Void>?

    internal let nwParametersConfigurator: (@Sendable (NWParameters) -> Void)?

    internal var parameters: NWParameters {
        let parameters = NWParameters(tls: self.tlsOptions, tcp: self.tcpOptions)
        self.nwParametersConfigurator?(parameters)
        return parameters
    }

    /// The TCP options for this connection.
    private var tcpOptions: NWProtocolTCP.Options

    internal var nwOptions: NWProtocolTCP.Options { self.tcpOptions }

    /// The TLS options for this connection, if any.
    private var tlsOptions: NWProtocolTLS.Options?

    /// The state of this connection channel.
    internal var state: ChannelState<ActiveSubstate> = .idle

    /// The active state, used for safely reporting the channel state across threads.
    internal let isActive0 = ManagedAtomic(false)

    /// The kinds of channel activation this channel supports
    internal let supportedActivationType: ActivationType = .connect

    /// Whether a call to NWConnection.receive has been made, but the completion
    /// handler has not yet been invoked.
    internal var outstandingRead: Bool = false

    /// The options for this channel.
    internal var options = TransportServicesChannelOptions()

    /// Any pending writes that have yet to be delivered to the network stack.
    internal var pendingWrites = CircularBuffer<PendingWrite>(initialCapacity: 8)

    /// An object to keep track of pending writes and manage our backpressure signaling.
    internal var _backpressureManager = BackpressureManager()

    /// The value of SO_REUSEADDR.
    internal var reuseAddress = false

    /// The value of SO_REUSEPORT.
    internal var reusePort = false

    /// The value of the allowLocalEndpointReuse option.
    internal var allowLocalEndpointReuse = false

    /// Whether to use peer-to-peer connectivity when connecting to Bonjour services.
    internal var enablePeerToPeer = false

    /// The default multipath service type.
    internal var multipathServiceType = NWParameters.MultipathServiceType.disabled

    /// The cache of the local and remote socket addresses. Must be accessed using _addressCacheLock.
    internal var _addressCache = AddressCache(local: nil, remote: nil)

    internal var addressCache: AddressCache {
        get {
            self._addressCacheLock.withLock {
                self._addressCache
            }
        }
        set {
            return self._addressCacheLock.withLock {
                self._addressCache = newValue
            }
        }
    }

    /// A lock that guards the _addressCache.
    internal let _addressCacheLock = NIOLock()

    /// The `NIOPooledRecvBufferAllocator` used to allocate buffers for incoming data
    private var recvBufferPool: NIOPooledRecvBufferAllocator

    /// A constant to hold the maximum amount of buffers that should be created by the `NIOPooledRecvBufferAllocator`
    ///
    /// Once we allow multiple messages per read on the channel, this should become a `maxMessagesPerRead` property
    /// and a corresponding channel option that users can configure.
    private let recvBufferPoolCapacity = 4

    /// Create a `NIOTSConnectionChannel` on a given `NIOTSEventLoop`.
    ///
    /// Note that `NIOTSConnectionChannel` objects cannot be created on arbitrary loops types.
    internal init(
        eventLoop: NIOTSEventLoop,
        parent: Channel? = nil,
        qos: DispatchQoS? = nil,
        minimumIncompleteReceiveLength: Int = 1,
        maximumReceiveLength: Int = 8192,
        tcpOptions: NWProtocolTCP.Options,
        tlsOptions: NWProtocolTLS.Options?,
        recvAllocator: RecvByteBufferAllocator = AdaptiveRecvByteBufferAllocator(),
        nwParametersConfigurator: (@Sendable (NWParameters) -> Void)?
    ) {
        self.tsEventLoop = eventLoop
        self.closePromise = eventLoop.makePromise()
        self.parent = parent
        self.minimumIncompleteReceiveLength = minimumIncompleteReceiveLength
        self.maximumReceiveLength = maximumReceiveLength
        self.connectionQueue = eventLoop.channelQueue(label: "nio.nioTransportServices.connectionchannel", qos: qos)
        self.tcpOptions = tcpOptions
        self.tlsOptions = tlsOptions
        self.recvBufferPool = .init(capacity: Int(self.recvBufferPoolCapacity), recvAllocator: recvAllocator)
        self.nwParametersConfigurator = nwParametersConfigurator

        // Must come last, as it requires self to be completely initialized.
        self._pipeline = ChannelPipeline(channel: self)
    }

    /// Create a `NIOTSConnectionChannel` with an already-established `NWConnection`.
    internal convenience init(
        wrapping connection: NWConnection,
        on eventLoop: NIOTSEventLoop,
        parent: Channel? = nil,
        qos: DispatchQoS? = nil,
        minimumIncompleteReceiveLength: Int = 1,
        maximumReceiveLength: Int = 8192,
        tcpOptions: NWProtocolTCP.Options,
        tlsOptions: NWProtocolTLS.Options?,
        recvAllocator: RecvByteBufferAllocator = AdaptiveRecvByteBufferAllocator(),
        nwParametersConfigurator: (@Sendable (NWParameters) -> Void)?
    ) {
        self.init(
            eventLoop: eventLoop,
            parent: parent,
            qos: qos,
            minimumIncompleteReceiveLength: minimumIncompleteReceiveLength,
            maximumReceiveLength: maximumReceiveLength,
            tcpOptions: tcpOptions,
            tlsOptions: tlsOptions,
            recvAllocator: recvAllocator,
            nwParametersConfigurator: nwParametersConfigurator
        )
        self.connection = connection
    }
}

// MARK:- NIOTSConnectionChannel implementation of Channel
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension NIOTSConnectionChannel: Channel {
    func getChannelSpecificOption0<Option>(option: Option) throws -> Option.Value where Option: ChannelOption {
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
            switch option {
            case is NIOTSChannelOptions.Types.NIOTSConnectionOption:
                return self.connection as! Option.Value
            default:
                // Fallthrough to non-restricted options.
                ()
            }
        }

        switch option {
        case is NIOTSChannelOptions.Types.NIOTSMultipathOption:
            return self.multipathServiceType as! Option.Value
        default:
            fatalError("option \(type(of: option)).\(option) not supported")
        }
    }

    func setChannelSpecificOption0<Option: ChannelOption>(option: Option, value: Option.Value) throws {
        self.eventLoop.preconditionInEventLoop()

        guard !self.closed else {
            throw ChannelError.ioOnClosedChannel
        }

        switch option {
        case is NIOTSChannelOptions.Types.NIOTSMultipathOption:
            self.multipathServiceType = value as! NIOTSChannelOptions.Types.NIOTSMultipathOption.Value
        default:
            fatalError("option \(type(of: option)).\(option) not supported")
        }
    }
}

// MARK:- NIOTSConnectionChannel implementation of StateManagedChannel.
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension NIOTSConnectionChannel: StateManagedChannel {
    typealias ActiveSubstate = TCPSubstate

    /// A TCP connection may be fully open or partially open. In the fully open state, both
    /// peers may send data. In the partially open states, only one of the two peers may send
    /// data.
    ///
    /// We keep track of this to manage the half-closure state of the TCP connection.
    enum TCPSubstate: NWConnectionSubstate {
        /// Both peers may send.
        case open

        /// This end of the connection has sent a FIN. We may only receive data.
        case halfClosedLocal

        /// The remote peer has sent a FIN. We may still send data, but cannot expect to
        /// receive more.
        case halfClosedRemote

        /// The channel is "active", but there can be no forward momentum here. The only valid
        /// thing to do in this state is drop the channel.
        case closed

        init() {
            self = .open
        }

        static func closeInput(state: inout ChannelState<NIOTSConnectionChannel.TCPSubstate>) throws {
            switch state {
            case .active(.open):
                state = .active(.halfClosedRemote)
            case .active(.halfClosedLocal):
                state = .active(.closed)
            case .idle, .registered, .activating, .active(.halfClosedRemote), .active(.closed), .inactive:
                throw NIOTSErrors.InvalidChannelStateTransition()
            }
        }

        static func closeOutput(state: inout ChannelState<NIOTSConnectionChannel.TCPSubstate>) throws {
            switch state {
            case .active(.open):
                state = .active(.halfClosedLocal)
            case .active(.halfClosedRemote):
                state = .active(.closed)
            case .active(.halfClosedLocal), .active(.closed):
                // This is a special case for closing the output, as it's user-controlled. If they already
                // closed it, we want to throw a special error to tell them.
                throw ChannelError.outputClosed
            case .idle, .registered, .activating, .inactive:
                throw NIOTSErrors.InvalidChannelStateTransition()
            }
        }
    }
}

// MARK:- Implementations of the callbacks passed to NWConnection.
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension NIOTSConnectionChannel {
    /// Called by the underlying `NWConnection` when a network receive has completed.
    ///
    /// The state matrix here is large. If `content` is non-nil, some data was received: we need to send it down the pipeline
    /// and call channelReadComplete. This may be nil, in which case we expect either `isComplete` to be `true` or `error`
    /// to be non-nil. `isComplete` indicates half-closure on the read side of a connection. `error` is set if the receive
    /// did not complete due to an error, though there may still be some data.
    private func dataReceivedHandler(
        content: Data?,
        context: NWConnection.ContentContext?,
        isComplete: Bool,
        error: NWError?
    ) {
        precondition(self.outstandingRead)
        self.outstandingRead = false

        guard self.isActive else {
            // If we're already not active, we aren't going to process any of this: it's likely the result of an extra
            // read somewhere along the line.
            return
        }

        // First things first, if there's data we need to deliver it.
        if let content = content {
            // It would be nice if we didn't have to do this copy, but I'm not sure how to avoid it with the current Data
            // APIs.
            let (buffer, bytesReceived) = self.recvBufferPool.buffer(allocator: allocator) { $0.writeBytes(content) }

            self.recvBufferPool.record(actualReadBytes: bytesReceived)
            self.pipeline.fireChannelRead(buffer)
            self.pipeline.fireChannelReadComplete()

        }

        // Next, we want to check if there's an error. If there is, we're going to deliver it, and then close the connection with
        // it. Otherwise, we're going to check if we read EOF, and if we did we'll close with that instead.
        if let error = error {
            self.pipeline.fireErrorCaught(error)
            self.close0(error: error, mode: .all, promise: nil)
        } else if isComplete {
            self.didReadEOF()
        }

        // Last, issue a new read automatically if we need to.
        self.readIfNeeded0()
    }

    /// Called by the underlying `NWConnection` when a better path for this connection is available.
    ///
    /// Notifies the channel pipeline of the new option.
    private func betterPathHandler(available: Bool) {
        if available {
            self.pipeline.fireUserInboundEventTriggered(NIOTSNetworkEvents.BetterPathAvailable())
        } else {
            self.pipeline.fireUserInboundEventTriggered(NIOTSNetworkEvents.BetterPathUnavailable())
        }
    }

    /// Called by the underlying `NWConnection` when a path becomes viable or non-viable
    ///
    /// Notifies the channel pipeline of the new viability.
    private func viabilityUpdateHandler(_ isViable: Bool) {
        self.pipeline.fireUserInboundEventTriggered(NIOTSNetworkEvents.ViabilityUpdate(isViable: isViable))
    }

    /// Called by the underlying `NWConnection` when this connection changes its network path.
    ///
    /// Notifies the channel pipeline of the new path.
    private func pathChangedHandler(newPath path: NWPath) {
        self.pipeline.fireUserInboundEventTriggered(NIOTSNetworkEvents.PathChanged(newPath: path))
    }
}

// MARK:- Implementations of state management for the channel.
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension NIOTSConnectionChannel {
    /// Whether the inbound side of the connection is still open.
    internal var _inboundStreamOpen: Bool {
        switch self.state {
        case .active(.open), .active(.halfClosedLocal):
            return true
        case .idle, .registered, .activating, .active, .inactive:
            return false
        }
    }

    /// Drop all outstanding writes. Must only be called in the inactive
    /// state.
    private func dropOutstandingWrites(error: Error) {
        while self.pendingWrites.count > 0 {
            self.pendingWrites.removeFirst().promise?.fail(error)
        }
    }

    /// Handle a read EOF.
    ///
    /// If the user has indicated they support half-closure, we will emit the standard half-closure
    /// event. If they have not, we upgrade this to regular closure.
    private func didReadEOF() {
        if self.options.supportRemoteHalfClosure {
            // This is a half-closure, but the connection is still valid.
            do {
                try ActiveSubstate.closeInput(state: &self.state)
            } catch {
                return self.close0(error: error, mode: .all, promise: nil)
            }

            self.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        } else {
            self.close0(error: ChannelError.eof, mode: .all, promise: nil)
        }
    }
}

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension NIOTSConnectionChannel {
    internal struct SynchronousOptions: NIOSynchronousChannelOptions {
        private let channel: NIOTSConnectionChannel

        fileprivate init(channel: NIOTSConnectionChannel) {
            self.channel = channel
        }

        public func setOption<Option: ChannelOption>(_ option: Option, value: Option.Value) throws {
            try self.channel.setOption0(option: option, value: value)
        }

        public func getOption<Option: ChannelOption>(_ option: Option) throws -> Option.Value {
            try self.channel.getOption0(option: option)
        }
    }

    public var syncOptions: NIOSynchronousChannelOptions? {
        SynchronousOptions(channel: self)
    }
}

public struct NIOTSConnectionNotInitialized: Error, Hashable {
    public init() {}
}

public struct NIOTSChannelIsNotANIOTSConnectionChannel: Error, Hashable {
    public init() {}
}

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension NIOTSConnectionChannel {
    fileprivate func metadata(definition: NWProtocolDefinition) throws -> NWProtocolMetadata? {
        guard let connection = self.connection else {
            throw NIOTSConnectionNotInitialized()
        }
        return connection.metadata(definition: definition)
    }
}

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension Channel {
    /// Retrieves the metadata for a specific protocol from the underlying ``NWConnection``
    /// - Throws: If `self` isn't a `NIOTS` channel with a `NWConnection` this method will throw
    /// ``NIOTSChannelIsNotATransportServicesChannel`` or ``NIOTSConnectionNotInitialized``.
    public func getMetadata(definition: NWProtocolDefinition) -> EventLoopFuture<NWProtocolMetadata?> {
        guard let channel = self as? NIOTSConnectionChannel else {
            return self.eventLoop.makeFailedFuture(NIOTSChannelIsNotANIOTSConnectionChannel())
        }
        if self.eventLoop.inEventLoop {
            return self.eventLoop.makeCompletedFuture {
                try channel.metadata(definition: definition)
            }
        } else {
            return self.eventLoop.submit {
                try channel.metadata(definition: definition)
            }
        }
    }

    /// Retrieves the metadata for a specific protocol from the underlying ``NWConnection``
    /// - Precondition: Must be called on the `EventLoop` the `Channel` is running on.
    /// - Throws: If `self` isn't a `NIOTS` channel with a `NWConnection` this method will throw
    /// ``NIOTSChannelIsNotATransportServicesChannel`` or ``NIOTSConnectionNotInitialized``.
    public func getMetadataSync(
        definition: NWProtocolDefinition,
        file: StaticString = #fileID,
        line: UInt = #line
    ) throws -> NWProtocolMetadata? {
        self.eventLoop.preconditionInEventLoop(file: file, line: line)
        guard let channel = self as? NIOTSConnectionChannel else {
            throw NIOTSChannelIsNotANIOTSConnectionChannel()
        }
        return try channel.metadata(definition: definition)
    }
}

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension NIOTSConnectionChannel: @unchecked Sendable {}

#endif
