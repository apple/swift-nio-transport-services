//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
#if canImport(Network)
import NIO

/// Options that can be set explicitly and only on bootstraps provided by `NIOTransportServices`.
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
public struct NIOTSChannelOptions {
    /// - seealso: `NIOTSWaitForActivityOption`.
    public static let waitForActivity = NIOTSChannelOptions.Types.NIOTSWaitForActivityOption()

    public static let enablePeerToPeer = NIOTSChannelOptions.Types.NIOTSEnablePeerToPeerOption()
}


@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension NIOTSChannelOptions {
    public enum Types {
        /// `NIOTSWaitForActivityOption` controls whether the `Channel` should wait for connection changes
        /// during the connection process if the connection attempt fails. If Network.framework believes that
        /// a connection may succeed in future, it may transition into the `.waiting` state. By default, this option
        /// is set to `true` and NIO allows this state transition, though it does count time in that state against
        /// the timeout. If this option is set to `false`, transitioning into this state will be treated the same as
        /// transitioning into the `failed` state, causing immediate connection failure.
        ///
        /// This option is only valid with `NIOTSConnectionBootstrap`.
        @available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
        public struct NIOTSWaitForActivityOption: ChannelOption, Equatable {
            public typealias Value = Bool

            public init() {}
        }


        /// `NIOTSEnablePeerToPeerOption` controls whether the `Channel` will advertise services using peer-to-peer
        /// connectivity. Setting this to true is the equivalent of setting `NWParameters.enablePeerToPeer` to
        /// `true`. By default this option is set to `false`.
        ///
        /// This option must be set on the bootstrap: setting it after the channel is initialized will have no effect.
        @available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
        public struct NIOTSEnablePeerToPeerOption: ChannelOption, Equatable {
            public typealias Value = Bool

            public init() {}
        }
    }
}

/// See: `NIOTSChannelOptions.Types.NIOTSWaitForActivityOption`.
@available(*, deprecated, renamed: "NIOTSChannelOptions.Types.NIOTSWaitForActivityOption")
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
public typealias NIOTSWaitForActivityOption = NIOTSChannelOptions.Types.NIOTSWaitForActivityOption


/// See: `NIOTSChannelOptions.Types.NIOTSEnablePeerToPeerOption`
@available(*, deprecated, renamed: "NIOTSChannelOptions.Types.NIOTSEnablePeerToPeerOption")
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
public typealias NIOTSEnablePeerToPeerOption = NIOTSChannelOptions.Types.NIOTSEnablePeerToPeerOption


#endif
