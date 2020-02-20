
//===----------------------------------------------------------------------===//

#if canImport(Network)
import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOFoundationCompat
import NIOTLS
import Dispatch
import Network
import Security

/// Execute the given function and synchronously complete the given `EventLoopPromise` (if not `nil`).
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
func executeAndComplete<T>(_ promise: EventLoopPromise<T>?, _ body: () throws -> T) {
    do {
        let result = try body()
        promise?.succeed(result)
    } catch let e {
        promise?.fail(e)
    }
}

/// Merge two possible promises together such that firing the result will fire both.
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
func mergePromises(_ first: EventLoopPromise<Void>?, _ second: EventLoopPromise<Void>?) -> EventLoopPromise<Void>? {
    if let first = first {
        if let second = second {
            first.futureResult.cascade(to: second)
        }
        return first
    } else {
        return second
    }
}

typealias PendingWrite = (data: ByteBuffer, promise: EventLoopPromise<Void>?)


/// A structure that manages backpressure signaling on this channel.
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
struct BackpressureManager {
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
    let writable = Atomic<Bool>(value: true)

    /// The number of bytes outstanding on the network.
    private var outstandingBytes: Int = 0

    /// The watermarks currently configured by the user.
    private(set) var waterMarks: WriteBufferWaterMark = WriteBufferWaterMark(low: 32 * 1024, high: 64 * 1024)

    /// Adds `newBytes` to the queue of outstanding bytes, and returns whether this
    /// has caused a writability change.
    ///
    /// - parameters:
    ///     - newBytes: the number of bytes queued to send, but not yet sent.
    /// - returns: Whether the state changed.
    mutating func writabilityChanges(whenQueueingBytes newBytes: Int) -> Bool {
        self.outstandingBytes += newBytes
        if self.outstandingBytes > self.waterMarks.high && self.writable.load() {
            self.writable.store(false)
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
        if self.outstandingBytes < self.waterMarks.low && !self.writable.load() {
            self.writable.store(true)
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
    mutating func writabilityChanges(whenUpdatingWaterMarks waterMarks: WriteBufferWaterMark) -> Bool {
        let writable = self.writable.load()
        self.waterMarks = waterMarks

        if writable && self.outstandingBytes > self.waterMarks.high {
            self.writable.store(false)
            return true
        } else if !writable && self.outstandingBytes < self.waterMarks.low {
            self.writable.store(true)
            return true
        }

        return false
    }
}

/// Channel options for the connection channel.
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
internal struct TransportServicesOptions {
    /// Whether autoRead is enabled for this channel.
    internal var autoRead: Bool = true

    /// Whether we support remote half closure. If not true, remote half closure will
    /// cause connection drops.
    internal var supportRemoteHalfClosure: Bool = false

    /// Whether this channel should wait for the connection to become active.
    internal var waitForActivity: Bool = true
}

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
internal final class NIOTSConnectionChannel: StateManagedNWConnectionChannel {
    var parameters: NWParameters {
        return NWParameters(tls: self.tlsOptions, tcp: self.tcpOptions)
    }
    
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
        
        /// Close the input side of the TCP state machine.
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

        /// Close the output side of the TCP state machine.
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
    
    public var supportsRemoteHalfClosure: Bool { false }
    
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

    private var _pipeline: ChannelPipeline! = nil  // this is really a constant (set in .init) but needs `self` to be constructed and therefore a `var`. Do not change as this needs to accessed from arbitrary threads.

    internal let closePromise: EventLoopPromise<Void>

    /// The underlying `NWConnection` that this `Channel` wraps. This is only non-nil
    /// after the initial connection attempt has been made.
    var _connection: NWConnection?

    /// The `DispatchQueue` that socket events for this connection will be dispatched onto.
    let _connectionQueue: DispatchQueue

    /// An `EventLoopPromise` that will be succeeded or failed when a connection attempt succeeds or fails.
    var _connectPromise: EventLoopPromise<Void>?

    /// The TCP options for this connection.
    private var tcpOptions: NWProtocolTCP.Options

    /// The TLS options for this connection, if any.
    private var tlsOptions: NWProtocolTLS.Options?

    /// The state of this connection channel.
    internal var state: ChannelState<ActiveSubstate> = .idle

    /// The active state, used for safely reporting the channel state across threads.
    internal var isActive0: Atomic<Bool> = Atomic(value: false)

    /// The kinds of channel activation this channel supports
    internal let supportedActivationType: ActivationType = .connect

    /// Whether a call to NWConnection.receive has been made, but the completion
    /// handler has not yet been invoked.
    var _outstandingRead: Bool = false

    /// The options for this channel.
    var _options: TransportServicesOptions = TransportServicesOptions()

    /// Any pending writes that have yet to be delivered to the network stack.
    var _pendingWrites = CircularBuffer<PendingWrite>(initialCapacity: 8)

    /// An object to keep track of pending writes and manage our backpressure signaling.
    var _backpressureManager = BackpressureManager()

    /// The value of SO_REUSEADDR.
    var _reuseAddress = false

    /// The value of SO_REUSEPORT.
    var _reusePort = false

    /// Whether to use peer-to-peer connectivity when connecting to Bonjour services.
    var _enablePeerToPeer = false

    /// Create a `NIOTSConnectionChannel` on a given `NIOTSEventLoop`.
    ///
    /// Note that `NIOTSConnectionChannel` objects cannot be created on arbitrary loops types.
    internal init(eventLoop: NIOTSEventLoop,
                  parent: Channel? = nil,
                  qos: DispatchQoS? = nil,
                  tcpOptions: NWProtocolTCP.Options,
                  tlsOptions: NWProtocolTLS.Options?) {
        self.tsEventLoop = eventLoop
        self.closePromise = eventLoop.makePromise()
        self.parent = parent
        self._connectionQueue = eventLoop.channelQueue(label: "nio.nioTransportServices.connectionchannel", qos: qos)
        self.tcpOptions = tcpOptions
        self.tlsOptions = tlsOptions

        // Must come last, as it requires self to be completely initialized.
        self._pipeline = ChannelPipeline(channel: self)
    }

    /// Create a `NIOTSConnectionChannel` with an already-established `NWConnection`.
    internal convenience init(wrapping connection: NWConnection,
                              on eventLoop: NIOTSEventLoop,
                              parent: Channel,
                              qos: DispatchQoS? = nil,
                              tcpOptions: NWProtocolTCP.Options,
                              tlsOptions: NWProtocolTLS.Options?) {
        self.init(eventLoop: eventLoop,
                  parent: parent,
                  qos: qos,
                  tcpOptions: tcpOptions,
                  tlsOptions: tlsOptions)
        self._connection = connection
    }
    
    /// Whether the inbound side of the connection is still open.
    var _inboundStreamOpen: Bool {
        switch self.state {
        case .active(.open), .active(.halfClosedLocal):
            return true
        case .idle, .registered, .activating, .active, .inactive:
            return false
        }
    }
}


// MARK:- NIOTSConnectionChannel implementation of Channel
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension NIOTSConnectionChannel: Channel {
    /// The `ChannelPipeline` for this `Channel`.
    public var pipeline: ChannelPipeline {
        return self._pipeline
    }

    /// The local address for this channel.
    public var localAddress: SocketAddress? {
        if self.eventLoop.inEventLoop {
            return try? self.localAddress0()
        } else {
            return self._connectionQueue.sync { try? self.localAddress0() }
        }
    }

    /// The remote address for this channel.
    public var remoteAddress: SocketAddress? {
        if self.eventLoop.inEventLoop {
            return try? self.remoteAddress0()
        } else {
            return self._connectionQueue.sync { try? self.remoteAddress0() }
        }
    }

    /// Whether this channel is currently writable.
    public var isWritable: Bool {
        return self._backpressureManager.writable.load()
    }

    public var _channelCore: ChannelCore {
        return self
    }

    public func setOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> EventLoopFuture<Void> {
        if eventLoop.inEventLoop {
            let promise: EventLoopPromise<Void> = eventLoop.makePromise()
            executeAndComplete(promise) { try setOption0(option: option, value: value) }
            return promise.futureResult
        } else {
            return eventLoop.submit { try self.setOption0(option: option, value: value) }
        }
    }

    private func setOption0<Option: ChannelOption>(option: Option, value: Option.Value) throws {
        self.eventLoop.assertInEventLoop()

        guard !self.closed else {
            throw ChannelError.ioOnClosedChannel
        }

        switch option {
        case _ as AutoReadOption:
            self._options.autoRead = value as! Bool
            self.readIfNeeded0()
        case _ as AllowRemoteHalfClosureOption where self.supportsRemoteHalfClosure:
            self._options.supportRemoteHalfClosure = value as! Bool
        case _ as SocketOption:
            let optionValue = option as! SocketOption

            // SO_REUSEADDR and SO_REUSEPORT are handled here.
            switch (optionValue.level, optionValue.name) {
            case (SOL_SOCKET, SO_REUSEADDR):
                self._reuseAddress = (value as! SocketOptionValue) != Int32(0)
            case (SOL_SOCKET, SO_REUSEPORT):
                self._reusePort = (value as! SocketOptionValue) != Int32(0)
            default:
                try self.tcpOptions.applyChannelOption(option: optionValue, value: value as! SocketOptionValue)
            }
        case _ as WriteBufferWaterMarkOption:
            if self._backpressureManager.writabilityChanges(whenUpdatingWaterMarks: value as! WriteBufferWaterMark) {
                self.pipeline.fireChannelWritabilityChanged()
            }
        case _ as NIOTSWaitForActivityOption:
            let newValue = value as! Bool
            self._options.waitForActivity = newValue

            if let state = self._connection?.state, case .waiting(let err) = state {
                // We're in waiting now, so we should drop the connection.
                self.close0(error: err, mode: .all, promise: nil)
            }
        case is NIOTSEnablePeerToPeerOption:
            self._enablePeerToPeer = value as! NIOTSEnablePeerToPeerOption.Value
        default:
            fatalError("option \(type(of: option)).\(option) not supported")
        }
    }

    public func getOption<Option: ChannelOption>(_ option: Option) -> EventLoopFuture<Option.Value> {
        if eventLoop.inEventLoop {
            let promise: EventLoopPromise<Option.Value> = eventLoop.makePromise()
            executeAndComplete(promise) { try getOption0(option: option) }
            return promise.futureResult
        } else {
            return eventLoop.submit { try self.getOption0(option: option) }
        }
    }

    func getOption0<Option: ChannelOption>(option: Option) throws -> Option.Value {
        self.eventLoop.assertInEventLoop()

        guard !self.closed else {
            throw ChannelError.ioOnClosedChannel
        }

        switch option {
        case _ as AutoReadOption:
            return self._options.autoRead as! Option.Value
        case _ as AllowRemoteHalfClosureOption:
            return self._options.supportRemoteHalfClosure as! Option.Value
        case _ as SocketOption:
            let optionValue = option as! SocketOption

            // SO_REUSEADDR and SO_REUSEPORT are handled here.
            switch (optionValue.level, optionValue.name) {
            case (SOL_SOCKET, SO_REUSEADDR):
                return Int32(self._reuseAddress ? 1 : 0) as! Option.Value
            case (SOL_SOCKET, SO_REUSEPORT):
                return Int32(self._reusePort ? 1 : 0) as! Option.Value
            default:
                return try self.tcpOptions.valueFor(socketOption: optionValue) as! Option.Value
            }
        case _ as WriteBufferWaterMarkOption:
            return self._backpressureManager.waterMarks as! Option.Value
        case _ as NIOTSWaitForActivityOption:
            return self._options.waitForActivity as! Option.Value
        case is NIOTSEnablePeerToPeerOption:
            return self._enablePeerToPeer as! Option.Value
        default:
            fatalError("option \(type(of: option)).\(option) not supported")
        }
    }
}
#endif
