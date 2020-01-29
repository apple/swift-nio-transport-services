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
import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOFoundationCompat
import NIOTLS
import Dispatch
import Network
import Security

/// Merge two possible promises together such that firing the result will fire both.
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
private func mergePromises(_ first: EventLoopPromise<Void>?, _ second: EventLoopPromise<Void>?) -> EventLoopPromise<Void>? {
    if let first = first {
        if let second = second {
            first.futureResult.cascade(to: second)
        }
        return first
    } else {
        return second
    }
}

/// Channel options for the connection channel.
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
private struct ConnectionChannelOptions {
    /// Whether autoRead is enabled for this channel.
    internal var autoRead: Bool = true
}

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
internal final class NIOTSDatagramChannel {
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
    private var nwConnection: NWConnection?

    /// The `DispatchQueue` that socket events for this connection will be dispatched onto.
    private let connectionQueue: DispatchQueue

    /// An `EventLoopPromise` that will be succeeded or failed when a connection attempt succeeds or fails.
    private var connectPromise: EventLoopPromise<Void>?

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
    private var options: ConnectionChannelOptions = ConnectionChannelOptions()

    /// Any pending writes that have yet to be delivered to the network stack.
    private var pendingWrites = CircularBuffer<PendingWrite>(initialCapacity: 8)

    /// An object to keep track of pending writes and manage our backpressure signaling.
    private var backpressureManager = BackpressureManager()

    /// The value of SO_REUSEADDR.
    private var reuseAddress = false

    /// The value of SO_REUSEPORT.
    private var reusePort = false

    /// Whether to use peer-to-peer connectivity when connecting to Bonjour services.
    private var enablePeerToPeer = false

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
        self.connectionQueue = eventLoop.channelQueue(label: "nio.nioTransportServices.connectionchannel", qos: qos)
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
        self.nwConnection = connection
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
            return self.connectionQueue.sync { try? self.localAddress0() }
        }
    }

    /// The remote address for this channel.
    public var remoteAddress: SocketAddress? {
        if self.eventLoop.inEventLoop {
            return try? self.remoteAddress0()
        } else {
            return self.connectionQueue.sync { try? self.remoteAddress0() }
        }
    }

    /// Whether this channel is currently writable.
    public var isWritable: Bool {
        return self.backpressureManager.writable.load()
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
            self.options.autoRead = value as! Bool
            self.readIfNeeded0()
        case _ as SocketOption:
            let optionValue = option as! SocketOption

            // SO_REUSEADDR and SO_REUSEPORT are handled here.
            switch (optionValue.level, optionValue.name) {
            case (SOL_SOCKET, SO_REUSEADDR):
                self.reuseAddress = (value as! SocketOptionValue) != Int32(0)
            case (SOL_SOCKET, SO_REUSEPORT):
                self.reusePort = (value as! SocketOptionValue) != Int32(0)
            default:
                try self.udpOptions.applyChannelOption(option: optionValue, value: value as! SocketOptionValue)
            }
        case _ as WriteBufferWaterMarkOption:
            if self.backpressureManager.writabilityChanges(whenUpdatingWaterMarks: value as! WriteBufferWaterMark) {
                self.pipeline.fireChannelWritabilityChanged()
            }
        case is NIOTSEnablePeerToPeerOption:
            self.enablePeerToPeer = value as! NIOTSEnablePeerToPeerOption.Value
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
            return self.options.autoRead as! Option.Value
        case _ as SocketOption:
            let optionValue = option as! SocketOption

            // SO_REUSEADDR and SO_REUSEPORT are handled here.
            switch (optionValue.level, optionValue.name) {
            case (SOL_SOCKET, SO_REUSEADDR):
                return Int32(self.reuseAddress ? 1 : 0) as! Option.Value
            case (SOL_SOCKET, SO_REUSEPORT):
                return Int32(self.reusePort ? 1 : 0) as! Option.Value
            default:
                return try self.udpOptions.valueFor(socketOption: optionValue) as! Option.Value
            }
        case _ as WriteBufferWaterMarkOption:
            return self.backpressureManager.waterMarks as! Option.Value
        case is NIOTSEnablePeerToPeerOption:
            return self.enablePeerToPeer as! Option.Value
        default:
            fatalError("option \(type(of: option)).\(option) not supported")
        }
    }
}


// MARK:- NIOTSDatagramConnectionChannel implementation of StateManagedChannel.
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension NIOTSDatagramChannel {
    typealias ActiveSubstate = UDPSubstate
    
    public var eventLoop: EventLoop {
        return self.tsEventLoop
    }

    /// Whether this channel is currently active.
    public var isActive: Bool {
        return self.isActive0.load()
    }

    /// Whether this channel is currently closed. This is not necessary for the public
    /// API, it's just a convenient helper.
    internal var closed: Bool {
        switch self.state {
        case .inactive:
            return true
        case .idle, .registered, .activating, .active:
            return false
        }
    }

    public func register0(promise: EventLoopPromise<Void>?) {
        // TODO: does this need to do anything more than this?
        do {
            try self.state.register(eventLoop: self.tsEventLoop, channel: self)
            self.pipeline.fireChannelRegistered()
            promise?.succeed(())
        } catch {
            promise?.fail(error)
            self.close0(error: error, mode: .all, promise: nil)
        }
    }

    public func registerAlreadyConfigured0(promise: EventLoopPromise<Void>?) {
        do {
            try self.state.register(eventLoop: self.tsEventLoop, channel: self)
            self.pipeline.fireChannelRegistered()
            try self.state.beginActivating()
            promise?.succeed(())
        } catch {
            promise?.fail(error)
            self.close0(error: error, mode: .all, promise: nil)
            return
        }

        // Ok, we are registered and ready to begin activating. Tell the channel: it must
        // call becomeActive0 directly.
        self.alreadyConfigured0(promise: promise)
    }

    public func connect0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        self.activateWithType(type: .connect, to: NWEndpoint(fromSocketAddress: address), promise: promise)
    }

    public func connect0(to endpoint: NWEndpoint, promise: EventLoopPromise<Void>?) {
        self.activateWithType(type: .connect, to: endpoint, promise: promise)
    }

    public func bind0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        self.activateWithType(type: .bind, to: NWEndpoint(fromSocketAddress: address), promise: promise)
    }

    public func bind0(to endpoint: NWEndpoint, promise: EventLoopPromise<Void>?) {
        self.activateWithType(type: .bind, to: endpoint, promise: promise)
    }
    
    public func bindAndConnect0(to endpoint: NWEndpoint, promise: EventLoopPromise<Void>?) {
        do {
            try self.state.beginActivating()
        } catch {
            promise?.fail(error)
            return
        }

        self.beginActivating0(to: endpoint, promise: promise)
    }

    public func close0(error: Error, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        switch mode {
        case .all:
            let oldState: ChannelState<ActiveSubstate>
            do {
                oldState = try self.state.becomeInactive()
            } catch let thrownError {
                promise?.fail(thrownError)
                return
            }

            self.isActive0.store(false)

            self.doClose0(error: error)

            switch oldState {
            case .active:
                self.pipeline.fireChannelInactive()
                fallthrough
            case .registered, .activating:
                self.tsEventLoop.deregister(self)
                self.pipeline.fireChannelUnregistered()
            case .idle:
                // If this was already idle we don't have anything to do.
                break
            case .inactive:
                preconditionFailure("Should be prevented by state machine")
            }

            // Next we fire the promise passed to this method.
            promise?.succeed(())

            // Now we schedule our final cleanup. We need to keep the channel pipeline alive for at least one more event
            // loop tick, as more work might be using it.
            self.eventLoop.execute {
                self.removeHandlers(channel: self)
                self.closePromise.succeed(())
            }
        case .input, .output:
            promise?.fail(ChannelError.operationUnsupported)
        }
    }

    public func becomeActive0(promise: EventLoopPromise<Void>?) {
        // Here we crash if we cannot transition our state. That's because my understanding is that we
        // should not be able to hit this.
        do {
            try self.state.becomeActive()
        } catch {
            self.close0(error: error, mode: .all, promise: promise)
            return
        }

        self.isActive0.store(true)
        promise?.succeed(())
        self.pipeline.fireChannelActive()
        self.readIfNeeded0()
    }

    /// A helper to handle the fact that activation is mostly common across connect and bind, and that both are
    /// not supported by a single channel type.
    private func activateWithType(type: ActivationType, to endpoint: NWEndpoint, promise: EventLoopPromise<Void>?) {
        do {
            try self.state.beginActivating()
        } catch {
            promise?.fail(error)
            return
        }

        self.beginActivating0(to: endpoint, promise: promise)
    }

    /// A UDP connection may be fully open or partially open. In the fully open state, both
    /// peers may send data. In the partially open states, only one of the two peers may send
    /// data.
    ///
    /// We keep track of this to manage the half-closure state of the UDP connection.
    enum UDPSubstate: ActiveChannelSubstate {
        /// Both peers may send.
        case open
        
        /// The channel is "active", but there can be no forward momentum here. The only valid
        /// thing to do in this state is drop the channel.
        case closed

        init() {
            self = .open
        }
    }

    public func localAddress0() throws -> SocketAddress {
        guard let localEndpoint = self.nwConnection?.currentPath?.localEndpoint else {
            throw NIOTSErrors.NoCurrentPath()
        }
        // TODO: Support wider range of address types.
        return try SocketAddress(fromNWEndpoint: localEndpoint)
    }

    public func remoteAddress0() throws -> SocketAddress {
        guard let remoteEndpoint = self.nwConnection?.currentPath?.remoteEndpoint else {
            throw NIOTSErrors.NoCurrentPath()
        }
        // TODO: Support wider range of address types.
        return try SocketAddress(fromNWEndpoint: remoteEndpoint)
    }

    internal func alreadyConfigured0(promise: EventLoopPromise<Void>?) {
        guard let connection = nwConnection else {
            promise?.fail(NIOTSErrors.NotPreConfigured())
            return
        }

        guard case .setup = connection.state else {
            promise?.fail(NIOTSErrors.NotPreConfigured())
            return
        }

        connection.stateUpdateHandler = self.stateUpdateHandler(newState:)
        connection.betterPathUpdateHandler = self.betterPathHandler
        connection.pathUpdateHandler = self.pathChangedHandler(newPath:)
        connection.start(queue: self.connectionQueue)
    }

    internal func beginActivating0(to target: NWEndpoint, promise: EventLoopPromise<Void>?) {
        assert(self.nwConnection == nil)
        assert(self.connectPromise == nil)
        self.connectPromise = promise

        let parameters = NWParameters(dtls: self.dtlsOptions, udp: self.udpOptions)

        // Network.framework munges REUSEADDR and REUSEPORT together, so we turn this on if we need
        // either.
        parameters.allowLocalEndpointReuse = self.reuseAddress || self.reusePort

        parameters.includePeerToPeer = self.enablePeerToPeer

        let connection = NWConnection(to: target, using: parameters)
        connection.stateUpdateHandler = self.stateUpdateHandler(newState:)
        connection.betterPathUpdateHandler = self.betterPathHandler
        connection.pathUpdateHandler = self.pathChangedHandler(newPath:)

        // Ok, state is ready. Let's go!
        self.nwConnection = connection
        connection.start(queue: self.connectionQueue)
    }

    public func write0(_ data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard self.isActive else {
            promise?.fail(ChannelError.ioOnClosedChannel)
            return
        }

        // TODO: We would ideally support all of IOData here, gotta work out how to do that without HOL blocking
        // all writes terribly.
        // My best guess at this time is that Data(contentsOf:) may mmap the file in question, which would let us
        // at least only block the network stack itself rather than our thread. I'm not certain though, especially
        // on Linux. Should investigate.
        let data = self.unwrapData(data, as: ByteBuffer.self)
        self.pendingWrites.append((data, promise))


        /// This may cause our writability state to change.
        if self.backpressureManager.writabilityChanges(whenQueueingBytes: data.readableBytes) {
            self.pipeline.fireChannelWritabilityChanged()
        }
    }

    public func flush0() {
        guard self.isActive else {
            return
        }

        guard let conn = self.nwConnection else {
            preconditionFailure("nwconnection cannot be nil while channel is active")
        }

        func completionCallback(promise: EventLoopPromise<Void>?, sentBytes: Int) -> ((NWError?) -> Void) {
            return { error in
                if let error = error {
                    promise?.fail(error)
                } else {
                    promise?.succeed(())
                }

                if self.backpressureManager.writabilityChanges(whenBytesSent: sentBytes) {
                    self.pipeline.fireChannelWritabilityChanged()
                }
            }
        }

        conn.batch {
            while self.pendingWrites.count > 0 {
                let write = self.pendingWrites.removeFirst()
                let buffer = write.data
                let content = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes)
                conn.send(content: content, completion: .contentProcessed(completionCallback(promise: write.promise, sentBytes: buffer.readableBytes)))
            }
        }
    }
    

    /// Perform a read from the network.
    ///
    /// This method has a slightly strange semantic, because we do not allow multiple reads at once. As a result, this
    /// is a *request* to read, and if there is a read already being processed then this method will do nothing.
    public func read0() {
        guard self.inboundStreamOpen && !self.outstandingRead else {
            return
        }

        guard let conn = self.nwConnection else {
            preconditionFailure("Connection should not be nil")
        }

        // TODO: Can we do something sensible with these numbers?
        self.outstandingRead = true
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192, completion: self.dataReceivedHandler(content:context:isComplete:error:))
    }

    public func doClose0(error: Error) {
        guard let conn = self.nwConnection else {
            // We don't have a connection to close here, so we're actually done. Our old state
            // was idle.
            assert(self.pendingWrites.count == 0)
            return
        }

        // Step 1 is to tell the network stack we're done.
        // TODO: Does this drop the connection fully, or can we keep receiving data? Must investigate.
        conn.cancel()

        // Step 2 is to fail all outstanding writes.
        self.dropOutstandingWrites(error: error)

        // Step 3 is to cancel a pending connect promise, if any.
        if let pendingConnect = self.connectPromise {
            self.connectPromise = nil
            pendingConnect.fail(error)
        }
    }

    public func triggerUserOutboundEvent0(_ event: Any, promise: EventLoopPromise<Void>?) {
        switch event {
        case let x as NIOTSNetworkEvents.ConnectToUDPNWEndpoint:
            self.bindAndConnect0(to: x.endpoint, promise: promise)
        default:
            promise?.fail(ChannelError.operationUnsupported)
        }
    }

    public func channelRead0(_ data: NIOAny) {
        // drop the data, do nothing
        return
    }

    public func errorCaught0(error: Error) {
        // Currently we don't do anything with errors that pass through the pipeline
        return
    }

    /// A function that will trigger a socket read if necessary.
    internal func readIfNeeded0() {
        if self.options.autoRead {
            self.pipeline.read()
        }
    }
}


// MARK:- Implementations of the callbacks passed to NWConnection.
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension NIOTSDatagramChannel {
    /// Called by the underlying `NWConnection` when its internal state has changed.
    private func stateUpdateHandler(newState: NWConnection.State) {
        switch newState {
        case .setup:
            preconditionFailure("Should not be told about this state.")
        case .waiting(let err):
            // In this state we've transitioned into waiting, presumably from active or closing. In this
            // version of NIO this is an error, but we should aim to support this at some stage.
            self.close0(error: err, mode: .all, promise: nil)
        case .preparing:
            // This just means connections are being actively established. We have no specific action
            // here.
            break
        case .ready:
            // Transitioning to ready means the connection was succeeded. Hooray!
            self.connectionComplete0()
        case .cancelled:
            // This is the network telling us we're closed. We don't need to actually do anything here
            // other than check our state is ok.
            assert(self.closed)
            self.nwConnection = nil
        case .failed(let err):
            // The connection has failed for some reason.
            self.close0(error: err, mode: .all, promise: nil)
        default:
            // This clause is here to help the compiler out: it's otherwise not able to
            // actually validate that the switch is exhaustive. Trust me, it is.
            fatalError("Unreachable")
        }
    }

    /// Called by the underlying `NWConnection` when a network receive has completed.
    ///
    /// The state matrix here is large. If `content` is non-nil, some data was received: we need to send it down the pipeline
    /// and call channelReadComplete. This may be nil, in which case we expect either `isComplete` to be `true` or `error`
    /// to be non-nil. `isComplete` indicates half-closure on the read side of a connection. `error` is set if the receive
    /// did not complete due to an error, though there may still be some data.
    private func dataReceivedHandler(content: Data?, context: NWConnection.ContentContext?, isComplete: Bool, error: NWError?) {
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
            var buffer = self.allocator.buffer(capacity: content.count)
            buffer.writeBytes(content)
            self.pipeline.fireChannelRead(NIOAny(buffer))
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

    /// Called by the underlying `NWConnection` when this connection changes its network path.
    ///
    /// Notifies the channel pipeline of the new path.
    private func pathChangedHandler(newPath path: NWPath) {
        self.pipeline.fireUserInboundEventTriggered(NIOTSNetworkEvents.PathChanged(newPath: path))
    }
}


// MARK:- Implementations of state management for the channel.
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension NIOTSDatagramChannel {
    /// Whether the inbound side of the connection is still open.
    private var inboundStreamOpen: Bool {
        switch self.state {
        case .active(.open):
            return true
        case .idle, .registered, .activating, .active, .inactive:
            return false
        }
    }

    /// Make the channel active.
    private func connectionComplete0() {
        let promise = self.connectPromise
        self.connectPromise = nil
        self.becomeActive0(promise: promise)

        if let metadata = self.nwConnection?.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
            // This is a TLS connection, we may need to fire some other events.
            let negotiatedProtocol = sec_protocol_metadata_get_negotiated_protocol(metadata.securityProtocolMetadata).map {
                String(cString: $0)
            }
            self.pipeline.fireUserInboundEventTriggered(TLSUserEvent.handshakeCompleted(negotiatedProtocol: negotiatedProtocol))
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
        self.close0(error: ChannelError.eof, mode: .all, promise: nil)
    }
}
#endif
