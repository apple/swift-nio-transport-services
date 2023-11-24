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
import XCTest
import NIOTransportServices
import NIOCore

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class NIOSingletonsTests: XCTestCase {
    func testNIOSingletonsTransportServicesEventLoopGroupWorks() async throws {
        let works = try await NIOSingletons.transportServicesEventLoopGroup.any().submit { "yes" }.get()
        XCTAssertEqual(works, "yes")
    }

    func testNIOTSEventLoopGroupSingletonWorks() async throws {
        let works = try await NIOTSEventLoopGroup.singleton.any().submit { "yes" }.get()
        XCTAssertEqual(works, "yes")
        XCTAssert(NIOTSEventLoopGroup.singleton === NIOSingletons.transportServicesEventLoopGroup)
    }

    func testSingletonGroupCannotBeShutDown() async throws {
        do {
            try await NIOTSEventLoopGroup.singleton.shutdownGracefully()
            XCTFail("shutdown worked, that's bad")
        } catch {
            XCTAssertEqual(EventLoopError.unsupportedOperation, error as? EventLoopError)
        }
    }

    func testSingletonLoopThatArePartOfGroupCannotBeShutDown() async throws {
        for loop in NIOTSEventLoopGroup.singleton.makeIterator() {
            do {
                try await loop.shutdownGracefully()
                XCTFail("shutdown worked, that's bad")
            } catch {
                XCTAssertEqual(EventLoopError.unsupportedOperation, error as? EventLoopError)
            }
        }
    }
}
#endif
