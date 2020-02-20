//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
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

    private var _pipeline: ChannelPipeline! = nil  // this is really a constant (set in .init) but needs `self` to be constructed and therefore a `var`. Do not change as this needs to accessed from arbitrary threads.

    internal let closePromise: EventLoopPromise<Void>

    /// The underlying `NWConnection` that this `Channel` wraps. This is only non-nil
    /// after the initial connection attempt has been made.
    internal var _connection: NWConnection?

    /// The `DispatchQueue` that socket events for this connection will be dispatched onto.
    internal let _connectionQueue: DispatchQueue

    /// An `EventLoopPromise` that will be succeeded or failed when a connection attempt succeeds or fails.
    internal var _connectPromise: EventLoopPromise<Void>?

    /// The UDP options for this connection.
    private var udpOptions: NWProtocolUDP.Options

    /// The TLS options for this connection, if any.
    private var dtlsOptions: NWProtocolTLS.Options?

    /// The state of this connection channel.
    internal var state: ChannelState<ActiveSubstate> = .idle

    /// The active state, used for safely reporting the channel state across threads.
    internal var isActive0: Atomic<Bool> = Atomic(value: false)

    /// Whether a call to NWConnection.receive has been made, but the completion
    /// handler has not yet been invoked.
    private var outstandingRead: Bool = false

    /// The options for this channel.
    internal var _options: TransportServicesOptions = TransportServicesOptions()

    /// Any pending writes that have yet to be delivered to the network stack.
    internal var _pendingWrites = CircularBuffer<PendingWrite>(initialCapacity: 8)

    /// An object to keep track of pending writes and manage our backpressure signaling.
    internal var _backpressureManager = BackpressureManager()

    /// The value of SO_REUSEADDR.
    internal var _reuseAddress = false

    /// The value of SO_REUSEPORT.
    internal var _reusePort = false

    /// Whether to use peer-to-peer connectivity when connecting to Bonjour services.
    internal var _enablePeerToPeer = false
    
    var parameters: NWParameters {
        NWParameters(dtls: self.dtlsOptions, udp: self.udpOptions)
    }
    
    var _outstandingRead: Bool = false
    
    var _inboundStreamOpen: Bool {
        switch self.state {
        case .active(.open):
            return true
        case .idle, .registered, .activating, .active, .inactive:
            return false
        }
    }
    

    /// Create a `NIOTSDatagramConnectionChannel` on a given `NIOTSEventLoop`.
    ///
    /// Note that `NIOTSDatagramConnectionChannel` objects cannot be created on arbitrary loops types.
    internal init(eventLoop: NIOTSEventLoop,
                  parent: Channel? = nil,
                  qos: DispatchQoS? = nil,
                  udpOptions: NWProtocolUDP.Options,
                  dtlsOptions: NWProtocolTLS.Options?) {
        self.tsEventLoop = eventLoop
        self.closePromise = eventLoop.makePromise()
        self.parent = parent
        self._connectionQueue = eventLoop.channelQueue(label: "nio.nioTransportServices.connectionchannel", qos: qos)
        self.udpOptions = udpOptions
        self.dtlsOptions = dtlsOptions

        // Must come last, as it requires self to be completely initialized.
        self._pipeline = ChannelPipeline(channel: self)
    }

    /// Create a `NIOTSDatagramConnectionChannel` with an already-established `NWConnection`.
    internal convenience init(wrapping connection: NWConnection,
                              on eventLoop: NIOTSEventLoop,
                              parent: Channel,
                              qos: DispatchQoS? = nil,
                              udpOptions: NWProtocolUDP.Options,
                              dtlsOptions: NWProtocolTLS.Options?) {
        self.init(eventLoop: eventLoop,
                  parent: parent,
                  qos: qos,
                  udpOptions: udpOptions,
                  dtlsOptions: dtlsOptions)
        self._connection = connection
    }
}


// MARK:- NIOTSDatagramConnectionChannel implementation of Channel
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension NIOTSDatagramChannel: Channel, ChannelCore {
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
        case _ as SocketOption:
            let optionValue = option as! SocketOption

            // SO_REUSEADDR and SO_REUSEPORT are handled here.
            switch (optionValue.level, optionValue.name) {
            case (SOL_SOCKET, SO_REUSEADDR):
                self._reuseAddress = (value as! SocketOptionValue) != Int32(0)
            case (SOL_SOCKET, SO_REUSEPORT):
                self._reusePort = (value as! SocketOptionValue) != Int32(0)
            default:
                try self.udpOptions.applyChannelOption(option: optionValue, value: value as! SocketOptionValue)
            }
        case _ as WriteBufferWaterMarkOption:
            if self._backpressureManager.writabilityChanges(whenUpdatingWaterMarks: value as! WriteBufferWaterMark) {
                self.pipeline.fireChannelWritabilityChanged()
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
        case _ as SocketOption:
            let optionValue = option as! SocketOption

            // SO_REUSEADDR and SO_REUSEPORT are handled here.
            switch (optionValue.level, optionValue.name) {
            case (SOL_SOCKET, SO_REUSEADDR):
                return Int32(self._reuseAddress ? 1 : 0) as! Option.Value
            case (SOL_SOCKET, SO_REUSEPORT):
                return Int32(self._reusePort ? 1 : 0) as! Option.Value
            default:
                return try self.udpOptions.valueFor(socketOption: optionValue) as! Option.Value
            }
        case _ as WriteBufferWaterMarkOption:
            return self._backpressureManager.waterMarks as! Option.Value
        case is NIOTSEnablePeerToPeerOption:
            return self._enablePeerToPeer as! Option.Value
        default:
            fatalError("option \(type(of: option)).\(option) not supported")
        }
    }
}
#endif
