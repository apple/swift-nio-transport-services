//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
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
import Network

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension NWProtocolUDP.Options: NWOptionsProtocol {
    /// Apply a given channel `SocketOption` to this protocol options state.
    func applyChannelOption(option: ChannelOptions.Types.SocketOption, value: SocketOptionValue) throws {
        throw NIOTSErrors.UnsupportedSocketOption(optionValue: option)
    }

    /// Obtain the given `SocketOption` value for this protocol options state.
    func valueFor(socketOption option: ChannelOptions.Types.SocketOption) throws -> SocketOptionValue {
        throw NIOTSErrors.UnsupportedSocketOption(optionValue: option)
    }
}
#endif
