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
import NIOFoundationCompat
import NIOConcurrencyHelpers
import Dispatch
import Network
import Atomics

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
internal final class NIOTSDatagramListenerChannel: StateManagedListenerChannel<NIOTSDatagramConnectionChannel> {
    /// The TCP options for this listener.
    private var udpOptions: NWProtocolUDP.Options {
        get {
            guard case .udp(let options) = protocolOptions else {
                fatalError("NIOTSDatagramListenerChannel did not have a UDP protocol state")
            }

            return options
        }
        set {
            assert(
                {
                    if case .udp = protocolOptions {
                        return true
                    } else {
                        return false
                    }
                }(),
                "The protocol options of this channel were not configured as UDP"
            )

            protocolOptions = .udp(newValue)
        }
    }

    /// The TCP options to use for child channels.
    private var childUDPOptions: NWProtocolUDP.Options {
        get {
            guard case .udp(let options) = childProtocolOptions else {
                fatalError("NIOTSDatagramListenerChannel did not have a UDP protocol state")
            }

            return options
        }
        set {
            assert(
                {
                    if case .udp = childProtocolOptions {
                        return true
                    } else {
                        return false
                    }
                }(),
                "The protocol options of child channelss were not configured as UDP"
            )

            childProtocolOptions = .udp(newValue)
        }
    }

    /// Create a `NIOTSDatagramListenerChannel` on a given `NIOTSEventLoop`.
    ///
    /// Note that `NIOTSDatagramListenerChannel` objects cannot be created on arbitrary loops types.
    internal convenience init(
        eventLoop: NIOTSEventLoop,
        qos: DispatchQoS? = nil,
        udpOptions: NWProtocolUDP.Options,
        tlsOptions: NWProtocolTLS.Options?,
        nwParametersConfigurator: (@Sendable (NWParameters) -> Void)?,
        childLoopGroup: EventLoopGroup,
        childChannelQoS: DispatchQoS?,
        childUDPOptions: NWProtocolUDP.Options,
        childTLSOptions: NWProtocolTLS.Options?,
        childNWParametersConfigurator: (@Sendable (NWParameters) -> Void)?
    ) {
        self.init(
            eventLoop: eventLoop,
            protocolOptions: .udp(udpOptions),
            tlsOptions: tlsOptions,
            nwParametersConfigurator: nwParametersConfigurator,
            childLoopGroup: childLoopGroup,
            childChannelQoS: childChannelQoS,
            childProtocolOptions: .udp(childUDPOptions),
            childTLSOptions: childTLSOptions,
            childNWParametersConfigurator: childNWParametersConfigurator
        )
    }

    /// Create a `NIOTSDatagramListenerChannel` with an already-established `NWListener`.
    internal convenience init(
        wrapping listener: NWListener,
        on eventLoop: NIOTSEventLoop,
        qos: DispatchQoS? = nil,
        udpOptions: NWProtocolUDP.Options,
        tlsOptions: NWProtocolTLS.Options?,
        nwParametersConfigurator: (@Sendable (NWParameters) -> Void)?,
        childLoopGroup: EventLoopGroup,
        childChannelQoS: DispatchQoS?,
        childUDPOptions: NWProtocolUDP.Options,
        childTLSOptions: NWProtocolTLS.Options?,
        childNWParametersConfigurator: (@Sendable (NWParameters) -> Void)?
    ) {
        self.init(
            wrapping: listener,
            eventLoop: eventLoop,
            protocolOptions: .udp(udpOptions),
            tlsOptions: tlsOptions,
            nwParametersConfigurator: nwParametersConfigurator,
            childLoopGroup: childLoopGroup,
            childChannelQoS: childChannelQoS,
            childProtocolOptions: .udp(childUDPOptions),
            childTLSOptions: childTLSOptions,
            childNWParametersConfigurator: childNWParametersConfigurator
        )
    }

    /// Called by the underlying `NWListener` when a new connection has been received.
    internal override func newConnectionHandler(connection: NWConnection) {
        guard self.isActive else {
            return
        }

        let newChannel = NIOTSDatagramConnectionChannel(
            wrapping: connection,
            on: self.childLoopGroup.next() as! NIOTSEventLoop,
            parent: self,
            udpOptions: self.childUDPOptions,
            tlsOptions: self.childTLSOptions,
            nwParametersConfigurator: self.childNWParametersConfigurator
        )

        self.pipeline.fireChannelRead(newChannel)
        self.pipeline.fireChannelReadComplete()
    }

    internal struct SynchronousOptions: NIOSynchronousChannelOptions {
        private let channel: NIOTSDatagramListenerChannel

        fileprivate init(channel: NIOTSDatagramListenerChannel) {
            self.channel = channel
        }

        public func setOption<Option: ChannelOption>(_ option: Option, value: Option.Value) throws {
            try self.channel.setOption0(option: option, value: value)
        }

        public func getOption<Option: ChannelOption>(_ option: Option) throws -> Option.Value {
            try self.channel.getOption0(option: option)
        }
    }

    public override var syncOptions: NIOSynchronousChannelOptions? {
        SynchronousOptions(channel: self)
    }
}

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension NIOTSDatagramListenerChannel: @unchecked Sendable {}

#endif
