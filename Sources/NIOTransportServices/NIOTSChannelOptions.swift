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
import NIOCore
import Network

/// Options that can be set explicitly and only on bootstraps provided by `NIOTransportServices`.
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
public struct NIOTSChannelOptions: Sendable {
    /// See: ``Types/NIOTSWaitForActivityOption``.
    public static let waitForActivity = NIOTSChannelOptions.Types.NIOTSWaitForActivityOption()

    /// See: ``Types/NIOTSEnablePeerToPeerOption``.
    public static let enablePeerToPeer = NIOTSChannelOptions.Types.NIOTSEnablePeerToPeerOption()

    /// See: ``Types/NIOTSAllowLocalEndpointReuse``.
    public static let allowLocalEndpointReuse = NIOTSChannelOptions.Types.NIOTSAllowLocalEndpointReuse()

    /// See: ``Types/NIOTSCurrentPathOption``.
    public static let currentPath = NIOTSChannelOptions.Types.NIOTSCurrentPathOption()

    /// See: ``Types/NIOTSMetadataOption``
    public static let metadata = {
        @Sendable (definition: NWProtocolDefinition) -> NIOTSChannelOptions.Types.NIOTSMetadataOption in
        .init(definition: definition)
    }

    /// See: ``Types/NIOTSEstablishmentReportOption``.
    @available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
    public static let establishmentReport = NIOTSChannelOptions.Types.NIOTSEstablishmentReportOption()

    /// See: ``Types/NIOTSDataTransferReportOption``.
    @available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
    public static let dataTransferReport = NIOTSChannelOptions.Types.NIOTSDataTransferReportOption()

    /// See: ``Types/NIOTSMultipathOption``
    public static let multipathServiceType = NIOTSChannelOptions.Types.NIOTSMultipathOption()

    /// See: ``Types/NIOTSConnectionOption``.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    public static let connection = NIOTSChannelOptions.Types.NIOTSConnectionOption()

    /// See: ``Types/NIOTSListenerOption``.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    public static let listener = NIOTSChannelOptions.Types.NIOTSListenerOption()

    /// See: ``Types/NIOTSMinimumIncompleteReceiveLengthOption``.
    public static let minimumIncompleteReceiveLength = NIOTSChannelOptions.Types
        .NIOTSMinimumIncompleteReceiveLengthOption()

    /// See: ``Types/NIOTSMaximumReceiveLengthOption``.
    public static let maximumReceiveLength = NIOTSChannelOptions.Types.NIOTSMaximumReceiveLengthOption()
}

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension NIOTSChannelOptions {
    /// A namespace for ``NIOTSChannelOptions`` datastructures.
    public enum Types: Sendable {
        /// ``NIOTSWaitForActivityOption`` controls whether the `Channel` should wait for connection changes
        /// during the connection process if the connection attempt fails. If Network.framework believes that
        /// a connection may succeed in future, it may transition into the `.waiting` state. By default, this option
        /// is set to `true` and NIO allows this state transition, though it does count time in that state against
        /// the timeout. If this option is set to `false`, transitioning into this state will be treated the same as
        /// transitioning into the `failed` state, causing immediate connection failure.
        ///
        /// This option is only valid with ``NIOTSConnectionBootstrap``.
        @available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
        public struct NIOTSWaitForActivityOption: ChannelOption, Equatable {
            public typealias Value = Bool

            public init() {}
        }

        /// ``NIOTSEnablePeerToPeerOption`` controls whether the `Channel` will advertise services using peer-to-peer
        /// connectivity. Setting this to true is the equivalent of setting `NWParameters.enablePeerToPeer` to
        /// `true`. By default this option is set to `false`.
        ///
        /// This option must be set on the bootstrap: setting it after the channel is initialized will have no effect.
        @available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
        public struct NIOTSEnablePeerToPeerOption: ChannelOption, Equatable {
            public typealias Value = Bool

            public init() {}
        }

        /// ``NIOTSAllowLocalEndpointReuse`` controls whether the `Channel` can reuse a TCP address recently used.
        ///  Setting this to true is the equivalent of setting at least one of `REUSEADDR` and `REUSEPORT` to
        /// `true`. By default this option is set to `false`.
        ///
        /// This option must be set on the bootstrap: setting it after the channel is initialized will have no effect.
        @available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
        public struct NIOTSAllowLocalEndpointReuse: ChannelOption, Equatable {
            public typealias Value = Bool

            public init() {}
        }

        /// ``NIOTSCurrentPathOption`` accesses the `NWConnection.currentPath` of the underlying connection.
        ///
        /// This option is only valid with ``NIOTSConnectionBootstrap``.
        @available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
        public struct NIOTSCurrentPathOption: ChannelOption, Equatable {
            public typealias Value = NWPath

            public init() {}
        }

        /// ``NIOTSMetadataOption`` accesses the metadata for a given `NWProtocol`.
        ///
        /// This option is only valid with ``NIOTSConnectionBootstrap``.
        @available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
        public struct NIOTSMetadataOption: ChannelOption, Equatable {
            public typealias Value = NWProtocolMetadata

            let definition: NWProtocolDefinition

            public init(definition: NWProtocolDefinition) {
                self.definition = definition
            }
        }

        /// ``NIOTSEstablishmentReportOption`` accesses the `NWConnection.EstablishmentReport` of the underlying connection.
        ///
        /// This option is only valid with ``NIOTSConnectionBootstrap``.
        @available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
        public struct NIOTSEstablishmentReportOption: ChannelOption, Equatable {
            public typealias Value = EventLoopFuture<NWConnection.EstablishmentReport?>

            public init() {}
        }

        /// ``NIOTSDataTransferReportOption`` accesses the `NWConnection.DataTransferReport` of the underlying connection.
        ///
        /// This option is only valid with ``NIOTSConnectionBootstrap``.
        @available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
        public struct NIOTSDataTransferReportOption: ChannelOption, Equatable {
            public typealias Value = NWConnection.PendingDataTransferReport

            public init() {}
        }

        /// ``NIOTSMultipathOption`` sets the multipath behaviour for a given `NWConnection`
        /// or `NWListener`.
        @available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
        public struct NIOTSMultipathOption: ChannelOption, Equatable {
            public typealias Value = NWParameters.MultipathServiceType

            public init() {}
        }

        /// ``NIOTSConnectionOption`` accesses the `NWConnection` of the underlying connection.
        ///
        /// > Warning: Callers must be extremely careful with this option, as it is easy to break an existing
        /// > connection that uses it. NIOTS doesn't support arbitrary modifications of the `NWConnection`
        /// > underlying a `Channel`.
        ///
        /// This option is only valid with a `Channel` backed by an `NWConnection`.
        @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
        public struct NIOTSConnectionOption: ChannelOption, Equatable {
            public typealias Value = NWConnection?

            public init() {}
        }

        /// ``NIOTSListenerOption`` accesses the `NWListener` of the underlying connection.
        ///
        /// > Warning: Callers must be extremely careful with this option, as it is easy to break an existing
        /// > connection that uses it. NIOTS doesn't support arbitrary modifications of the `NWListener`
        /// > underlying a `Channel`.
        ///
        /// This option is only valid with a `Channel` backed by an `NWListener`.
        @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
        public struct NIOTSListenerOption: ChannelOption, Equatable {
            public typealias Value = NWListener?

            public init() {}
        }

        /// ``NIOTSMinimumIncompleteReceiveLengthOption`` controls the minimum length to receive from a given
        /// `NWConnection`, until the content is complete.
        ///
        /// This option is only valid with a `Channel` backed by an `NWConnection`.
        public struct NIOTSMinimumIncompleteReceiveLengthOption: ChannelOption, Equatable {
            public typealias Value = Int

            public init() {}
        }

        /// ``NIOTSMaximumReceiveLengthOption`` controls the maximum length to receive from a given
        /// `NWConnection` in a single completion.
        ///
        /// This option is only valid with a `Channel` backed by an `NWConnection`.
        public struct NIOTSMaximumReceiveLengthOption: ChannelOption, Equatable {
            public typealias Value = Int

            public init() {}
        }
    }
}

/// See: ``NIOTSChannelOptions/Types/NIOTSWaitForActivityOption``.
@available(*, deprecated, renamed: "NIOTSChannelOptions.Types.NIOTSWaitForActivityOption")
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
public typealias NIOTSWaitForActivityOption = NIOTSChannelOptions.Types.NIOTSWaitForActivityOption

/// See: ``NIOTSChannelOptions/Types/NIOTSEnablePeerToPeerOption``
@available(*, deprecated, renamed: "NIOTSChannelOptions.Types.NIOTSEnablePeerToPeerOption")
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
public typealias NIOTSEnablePeerToPeerOption = NIOTSChannelOptions.Types.NIOTSEnablePeerToPeerOption

#endif
