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
import NIOCore
import NIOConcurrencyHelpers
import NIOFoundationCompat
import NIOTLS
import Dispatch
import Network
import Security

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
protocol NWConnectionSubstate: ActiveChannelSubstate {
    static func closeInput(state: inout ChannelState<Self>) throws
    static func closeOutput(state: inout ChannelState<Self>) throws
}

internal typealias PendingWrite = (data: ByteBuffer, promise: EventLoopPromise<Void>?)

protocol NWOptionsProtocol {
    /// Apply a given channel `SocketOption` to this protocol options state.
    func applyChannelOption(option: ChannelOptions.Types.SocketOption, value: SocketOptionValue) throws

    /// Obtain the given `SocketOption` value for this protocol options state.
    func valueFor(socketOption option: ChannelOptions.Types.SocketOption) throws -> SocketOptionValue
}

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
internal protocol StateManagedNWConnectionChannel: StateManagedChannel where ActiveSubstate: NWConnectionSubstate {
    associatedtype NWOptions: NWOptionsProtocol

    var parameters: NWParameters { get }

    var nwOptions: NWOptions { get }

    var connection: NWConnection? { get set }

    var minimumIncompleteReceiveLength: Int { get set }

    var maximumReceiveLength: Int { get set }

    var connectionQueue: DispatchQueue { get }

    var connectPromise: EventLoopPromise<Void>? { get set }

    var outstandingRead: Bool { get set }

    var options: TransportServicesChannelOptions { get set }

    var pendingWrites: CircularBuffer<PendingWrite> { get set }

    var _backpressureManager: BackpressureManager { get set }

    var reuseAddress: Bool { get set }

    var reusePort: Bool { get set }

    var enablePeerToPeer: Bool { get set }

    var _inboundStreamOpen: Bool { get }

    var _pipeline: ChannelPipeline! { get }

    var _addressCache: AddressCache { get set }

    var _addressCacheLock: NIOLock { get }

    var allowLocalEndpointReuse: Bool { get set }

    var multipathServiceType: NWParameters.MultipathServiceType { get }

    var nwParametersConfigurator: (@Sendable (NWParameters) -> Void)? { get }

    /// Indicates whether this connection channel carries datagrams (UDP) rather than a byte stream (TCP/TLS).
    /// Defaults to `false` and is overridden by datagram-specific channel implementations.
    var isDatagramChannel: Bool { get }

    func setChannelSpecificOption0<Option: ChannelOption>(option: Option, value: Option.Value) throws

    func getChannelSpecificOption0<Option: ChannelOption>(option: Option) throws -> Option.Value
}

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension StateManagedNWConnectionChannel {
    public var pipeline: ChannelPipeline {
        self._pipeline
    }

    public var _channelCore: ChannelCore {
        self
    }

    internal var isDatagramChannel: Bool { false }

    /// The local address for this channel.
    public var localAddress: SocketAddress? {
        self._addressCacheLock.withLock {
            self._addressCache.local
        }
    }

    /// The remote address for this channel.
    public var remoteAddress: SocketAddress? {
        self._addressCacheLock.withLock {
            self._addressCache.remote
        }
    }

    /// Whether this channel is currently writable.
    public var isWritable: Bool {
        self._backpressureManager.writable.load(ordering: .relaxed)
    }

    internal func beginActivating0(to target: NWEndpoint, promise: EventLoopPromise<Void>?) {
        assert(self.connection == nil)
        assert(self.connectPromise == nil)

        // Before we start, we validate that the target won't cause a crash: see
        // https://github.com/apple/swift-nio/issues/1617.
        if case .hostPort(host: let host, port: _) = target, host == "" {
            // We don't pass the promise in here because we'll actually not complete it. We complete it manually ourselves.
            self.close0(error: NIOTSErrors.InvalidHostname(), mode: .all, promise: nil)
            promise?.fail(NIOTSErrors.InvalidHostname())
            return
        }

        self.connectPromise = promise

        let parameters = parameters

        // Network.framework munges REUSEADDR and REUSEPORT together, so we turn this on if we need
        // either or it's been explicitly set.
        parameters.allowLocalEndpointReuse = self.reuseAddress || self.reusePort || self.allowLocalEndpointReuse

        parameters.includePeerToPeer = self.enablePeerToPeer

        parameters.multipathServiceType = self.multipathServiceType

        let connection = NWConnection(to: target, using: parameters)
        connection.stateUpdateHandler = self.stateUpdateHandler(newState:)
        connection.betterPathUpdateHandler = self.betterPathHandler
        connection.viabilityUpdateHandler = self.viabilityUpdateHandler
        connection.pathUpdateHandler = self.pathChangedHandler(newPath:)

        // Ok, state is ready. Let's go!
        self.connection = connection
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
        if self._backpressureManager.writabilityChanges(whenQueueingBytes: data.readableBytes) {
            self.pipeline.fireChannelWritabilityChanged()
        }
    }

    public func flush0() {
        guard self.isActive else {
            return
        }

        guard let conn = self.connection else {
            preconditionFailure("nwconnection cannot be nil while channel is active")
        }

        func completionCallback(promise: EventLoopPromise<Void>?, sentBytes: Int) -> (@Sendable (NWError?) -> Void) {
            { error in
                if let error = error {
                    promise?.fail(error)
                } else {
                    promise?.succeed(())
                }

                if self._backpressureManager.writabilityChanges(whenBytesSent: sentBytes) {
                    self.pipeline.fireChannelWritabilityChanged()
                }
            }
        }

        conn.batch {
            while self.pendingWrites.count > 0 {
                let write = self.pendingWrites.removeFirst()
                let buffer = write.data
                let content = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes)
                conn.send(
                    content: content,
                    completion: .contentProcessed(
                        completionCallback(promise: write.promise, sentBytes: buffer.readableBytes)
                    )
                )
            }
        }
    }

    public func localAddress0() throws -> SocketAddress {
        guard let localEndpoint = self.connection?.currentPath?.localEndpoint else {
            throw NIOTSErrors.NoCurrentPath()
        }
        // TODO: Support wider range of address types.
        return try SocketAddress(fromNWEndpoint: localEndpoint)
    }

    public func remoteAddress0() throws -> SocketAddress {
        guard let remoteEndpoint = self.connection?.currentPath?.remoteEndpoint else {
            throw NIOTSErrors.NoCurrentPath()
        }
        // TODO: Support wider range of address types.
        return try SocketAddress(fromNWEndpoint: remoteEndpoint)
    }

    internal func alreadyConfigured0(promise: EventLoopPromise<Void>?) {
        guard let connection = connection else {
            promise?.fail(NIOTSErrors.NotPreConfigured())
            return
        }

        guard case .setup = connection.state else {
            promise?.fail(NIOTSErrors.NotPreConfigured())
            return
        }
        self.connectPromise = promise
        connection.stateUpdateHandler = self.stateUpdateHandler(newState:)
        connection.betterPathUpdateHandler = self.betterPathHandler
        connection.viabilityUpdateHandler = self.viabilityUpdateHandler
        connection.pathUpdateHandler = self.pathChangedHandler(newPath:)
        self.nwParametersConfigurator?(connection.parameters)
        connection.start(queue: self.connectionQueue)
    }

    /// Perform a read from the network.
    ///
    /// This method has a slightly strange semantic, because we do not allow multiple reads at once. As a result, this
    /// is a *request* to read, and if there is a read already being processed then this method will do nothing.
    public func read0() {
        guard self._inboundStreamOpen && !self.outstandingRead else {
            return
        }

        guard let conn = self.connection else {
            preconditionFailure("Connection should not be nil")
        }

        self.outstandingRead = true

        conn.receive(
            minimumIncompleteLength: self.minimumIncompleteReceiveLength,
            maximumLength: self.maximumReceiveLength,
            completion: self.dataReceivedHandler(content:context:isComplete:error:)
        )
    }

    public func doClose0(error: Error) {
        guard let conn = self.connection else {
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

        // Step 4 Forward the connection state failed Error
        let channelError = error as? ChannelError
        if channelError != .eof {
            self.pipeline.fireErrorCaught(error)
        }
    }

    public func doHalfClose0(error: Error, promise: EventLoopPromise<Void>?) {
        guard let conn = self.connection else {
            // We don't have a connection to half close, so fail the promise.
            promise?.fail(ChannelError.ioOnClosedChannel)
            return
        }

        do {
            try ActiveSubstate.closeOutput(state: &self.state)
        } catch ChannelError.outputClosed {
            // Here we *only* fail the promise, no need to blow up the connection.
            promise?.fail(ChannelError.outputClosed)
            return
        } catch {
            // For any other error, this is fatal.
            self.close0(error: error, mode: .all, promise: promise)
            return
        }

        func completionCallback(for promise: EventLoopPromise<Void>?) -> (@Sendable (NWError?) -> Void) {
            { error in
                if let error = error {
                    promise?.fail(error)
                } else {
                    promise?.succeed(())
                }
            }
        }

        // It should not be possible to have a pending connect promise while we're doing half-closure.
        assert(self.connectPromise == nil)

        // Step 1 is to tell the network stack we're done.
        conn.send(
            content: nil,
            contentContext: .finalMessage,
            completion: .contentProcessed(completionCallback(for: promise))
        )

        // Step 2 is to fail all outstanding writes.
        self.dropOutstandingWrites(error: error)
    }

    public func triggerUserOutboundEvent0(_ event: Any, promise: EventLoopPromise<Void>?) {
        switch event {
        case let x as NIOTSNetworkEvents.ConnectToNWEndpoint:
            self.connect0(to: x.endpoint, promise: promise)
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

    /// Called by the underlying `NWConnection` when its internal state has changed.
    private func stateUpdateHandler(newState: NWConnection.State) {
        switch newState {
        case .setup:
            // Since iOS 18, we are occasionally informed of a change into this state.
            // We have no specific action here.
            break
        case .waiting(let err):
            if case .activating = self.state, self.options.waitForActivity {
                // This means the connection cannot currently be completed. We should notify the pipeline
                // here, or support this with a channel option or something, but for now for the sake of
                // demos we will just allow ourselves into this stage.tage.
                self.pipeline.fireUserInboundEventTriggered(
                    NIOTSNetworkEvents.WaitingForConnectivity(transientError: err)
                )
                break
            }

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
            self.connection = nil
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
            var buffer = self.allocator.buffer(capacity: content.count)
            buffer.writeBytes(content)
            self.pipeline.fireChannelRead(buffer)
            self.pipeline.fireChannelReadComplete()
        }

        // Next, we want to check if there's an error. If there is, we're going to deliver it, and then close the connection with
        // it. Otherwise, we're going to check if we read EOF, and if we did we'll close with that instead.
        //
        // Important: For datagram (UDP) connections, Network.framework reports `isComplete == true` for each
        // received datagram. This does NOT indicate stream EOF. Treating it as EOF closes the connected UDP
        // channel after the first packet ("one‑shot"). Guard against this by only considering `isComplete`
        // a real EOF on non-datagram (stream) channels.
        if let error = error {
            self.pipeline.fireErrorCaught(error)
            self.close0(error: error, mode: .all, promise: nil)
        } else if isComplete && !self.isDatagramChannel {
            // Only streams should translate `isComplete` into EOF. For datagrams, continue receiving.
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
    /// Make the channel active.
    private func connectionComplete0() {
        let promise = self.connectPromise
        self.connectPromise = nil

        // Before becoming active, update the cached addresses.
        let localAddress = try? self.localAddress0()
        let remoteAddress = try? self.remoteAddress0()

        self._addressCache = AddressCache(local: localAddress, remote: remoteAddress)

        self.becomeActive0(promise: promise)

        if let metadata = self.connection?.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
            // This is a TLS connection, we may need to fire some other events.
            let securityMetadata = metadata.securityProtocolMetadata

            // The pointer returned by `sec_protocol_metadata_get_negotiated_protocol` is presumably owned by it, so we need
            // to confirm it's still alive while we copy the data out.
            let negotiatedProtocol = withExtendedLifetime(securityMetadata) {
                sec_protocol_metadata_get_negotiated_protocol(metadata.securityProtocolMetadata).map {
                    String(cString: $0)
                }
            }

            self.pipeline.fireUserInboundEventTriggered(
                TLSUserEvent.handshakeCompleted(negotiatedProtocol: negotiatedProtocol)
            )
        }
    }

    /// Drop all outstanding writes. Must only be called in the inactive
    /// state.
    private func dropOutstandingWrites(error: Error) {
        while self.pendingWrites.count > 0 {
            self.pendingWrites.removeFirst().promise?.fail(error)
        }
    }

    public func setOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> EventLoopFuture<Void> {
        if self.eventLoop.inEventLoop {
            return self.eventLoop.makeCompletedFuture(Result { try setOption0(option: option, value: value) })
        } else {
            return self.eventLoop.submit { try self.setOption0(option: option, value: value) }
        }
    }

    func setOption0<Option: ChannelOption>(option: Option, value: Option.Value) throws {
        self.eventLoop.assertInEventLoop()

        guard !self.closed else {
            throw ChannelError.ioOnClosedChannel
        }

        switch option {
        case _ as ChannelOptions.Types.AutoReadOption:
            self.options.autoRead = value as! Bool
            self.readIfNeeded0()
        case _ as ChannelOptions.Types.SocketOption:
            let optionValue = option as! ChannelOptions.Types.SocketOption

            // SO_REUSEADDR and SO_REUSEPORT are handled here.
            switch (optionValue.level, optionValue.name) {
            case (SOL_SOCKET, SO_REUSEADDR):
                self.reuseAddress = (value as! SocketOptionValue) != Int32(0)
            case (SOL_SOCKET, SO_REUSEPORT):
                self.reusePort = (value as! SocketOptionValue) != Int32(0)
            default:
                try self.nwOptions.applyChannelOption(option: optionValue, value: value as! SocketOptionValue)
            }
        case _ as ChannelOptions.Types.WriteBufferWaterMarkOption:
            if self._backpressureManager.writabilityChanges(
                whenUpdatingWaterMarks: value as! ChannelOptions.Types.WriteBufferWaterMark
            ) {
                self.pipeline.fireChannelWritabilityChanged()
            }
        case is NIOTSChannelOptions.Types.NIOTSEnablePeerToPeerOption:
            self.enablePeerToPeer = value as! NIOTSChannelOptions.Types.NIOTSEnablePeerToPeerOption.Value
        case _ as NIOTSChannelOptions.Types.NIOTSWaitForActivityOption:
            let newValue = value as! Bool
            self.options.waitForActivity = newValue

            if let state = self.connection?.state, case .waiting(let err) = state, !newValue {
                // We're in waiting now, so we should drop the connection.
                self.close0(error: err, mode: .all, promise: nil)
            }
        case _ as ChannelOptions.Types.AllowRemoteHalfClosureOption:
            self.options.supportRemoteHalfClosure = value as! Bool
        case is NIOTSChannelOptions.Types.NIOTSAllowLocalEndpointReuse:
            self.allowLocalEndpointReuse = value as! NIOTSChannelOptions.Types.NIOTSAllowLocalEndpointReuse.Value
        case is NIOTSChannelOptions.Types.NIOTSMinimumIncompleteReceiveLengthOption:
            self.minimumIncompleteReceiveLength =
                value as! NIOTSChannelOptions.Types.NIOTSMinimumIncompleteReceiveLengthOption.Value
        case is NIOTSChannelOptions.Types.NIOTSMaximumReceiveLengthOption:
            self.maximumReceiveLength = value as! NIOTSChannelOptions.Types.NIOTSMaximumReceiveLengthOption.Value
        default:
            try self.setChannelSpecificOption0(option: option, value: value)
        }
    }

    public func getOption<Option: ChannelOption>(_ option: Option) -> EventLoopFuture<Option.Value> {
        if self.eventLoop.inEventLoop {
            return self.eventLoop.makeCompletedFuture(Result { try getOption0(option: option) })
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
        case _ as ChannelOptions.Types.AutoReadOption:
            return self.options.autoRead as! Option.Value
        case _ as ChannelOptions.Types.SocketOption:
            let optionValue = option as! ChannelOptions.Types.SocketOption

            // SO_REUSEADDR and SO_REUSEPORT are handled here.
            switch (optionValue.level, optionValue.name) {
            case (SOL_SOCKET, SO_REUSEADDR):
                return Int32(self.reuseAddress ? 1 : 0) as! Option.Value
            case (SOL_SOCKET, SO_REUSEPORT):
                return Int32(self.reusePort ? 1 : 0) as! Option.Value
            default:
                return try self.nwOptions.valueFor(socketOption: optionValue) as! Option.Value
            }
        case _ as ChannelOptions.Types.WriteBufferWaterMarkOption:
            return self._backpressureManager.waterMarks as! Option.Value
        case is NIOTSChannelOptions.Types.NIOTSEnablePeerToPeerOption:
            return self.enablePeerToPeer as! Option.Value
        case is NIOTSChannelOptions.Types.NIOTSAllowLocalEndpointReuse:
            return self.allowLocalEndpointReuse as! Option.Value
        case _ as ChannelOptions.Types.AllowRemoteHalfClosureOption:
            return self.options.supportRemoteHalfClosure as! Option.Value
        case _ as NIOTSChannelOptions.Types.NIOTSWaitForActivityOption:
            return self.options.waitForActivity as! Option.Value
        case is NIOTSChannelOptions.Types.NIOTSCurrentPathOption:
            guard let currentPath = self.connection?.currentPath else {
                throw NIOTSErrors.NoCurrentPath()
            }
            return currentPath as! Option.Value
        case is NIOTSChannelOptions.Types.NIOTSMetadataOption:
            let optionValue = option as! NIOTSChannelOptions.Types.NIOTSMetadataOption
            guard let connection = self.connection else {
                throw NIOTSErrors.NoCurrentConnection()
            }
            return connection.metadata(definition: optionValue.definition) as! Option.Value
        case is NIOTSChannelOptions.Types.NIOTSMinimumIncompleteReceiveLengthOption:
            return self.minimumIncompleteReceiveLength as! Option.Value
        case is NIOTSChannelOptions.Types.NIOTSMaximumReceiveLengthOption:
            return self.maximumReceiveLength as! Option.Value
        default:
            // watchOS 6.0 availability is covered by the @available on this extension.
            if #available(OSX 10.15, iOS 13.0, tvOS 13.0, *) {
                switch option {
                case is NIOTSChannelOptions.Types.NIOTSEstablishmentReportOption:
                    guard let connection = self.connection else {
                        throw NIOTSErrors.NoCurrentConnection()
                    }
                    let promise: EventLoopPromise<NWConnection.EstablishmentReport?> = eventLoop.makePromise()
                    connection.requestEstablishmentReport(queue: connectionQueue) { report in
                        promise.succeed(report)
                    }
                    return promise.futureResult as! Option.Value
                case is NIOTSChannelOptions.Types.NIOTSDataTransferReportOption:
                    guard let connection = self.connection else {
                        throw NIOTSErrors.NoCurrentConnection()
                    }
                    return connection.startDataTransferReport() as! Option.Value
                default:
                    break
                }
            }

            return try getChannelSpecificOption0(option: option)
        }
    }
}
#endif
