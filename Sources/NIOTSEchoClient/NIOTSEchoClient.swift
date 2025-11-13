//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2025 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// Build/Run (from repo root):
//   cd swift-nio-transport-services
//   swift run NIOTSEchoClient 127.0.0.1 9999
//
// Server: use SwiftNIO's UDP echo server (NIOUDPEchoServer).
// In a SwiftNIO checkout that contains Sources/NIOUDPEchoServer, run:
//   swift run NIOUDPEchoServer 127.0.0.1 9999
//

#if canImport(Network)

import NIOCore
import NIOTransportServices
import Darwin

@available(macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
final class EchoHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func channelActive(context: ChannelHandlerContext) {
        print("Channel active")
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = self.unwrapInboundIn(data)
        let text = buf.readString(length: buf.readableBytes) ?? "<\(buf.readableBytes) bytes>"
        print("echo:", text)
    }

    func channelInactive(context: ChannelHandlerContext) {
        print("Channel inactive (closed)")
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("error:", error)
        // Intentionally do not close here; keep running to observe behavior.
    }
}

@main
struct NIOTSEchoClient {
    static func main() throws {
        if #available(macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *) {
            let args = CommandLine.arguments
            let host = args.count > 1 ? args[1] : "127.0.0.1"
            let port = (args.count > 2 ? Int(args[2]) : nil) ?? 9999

            let group = NIOTSEventLoopGroup(loopCount: 1)

            // Use the connected-UDP bootstrap (aka NIOTSDatagramBootstrap via typealias).
            let bootstrap = NIOTSDatagramConnectionBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(EchoHandler())
                    }
                }

            let channel = try bootstrap.connect(host: host, port: port).wait()
            print("Connected to \(host):\(port) — start typing. Ctrl-C to exit.")

            // If the channel closes (remote or local), shut down the group and exit.
            channel.closeFuture.whenComplete { _ in
                // Best-effort shutdown and process exit for a CLI.
                _ = try? group.syncShutdownGracefully()
                // Exit the process to stop stdin loop if still running.
                exit(0)
            }

            // Read lines from stdin and send each line as a datagram.
            while let line = readLine(strippingNewline: true) {
                channel.eventLoop.execute {
                    var buf = channel.allocator.buffer(capacity: line.utf8.count)
                    buf.writeString(line)
                    channel.writeAndFlush(buf).whenFailure { error in
                        print("write failed:", error)
                    }
                }
            }

            // Optional graceful shutdown on EOF (Ctrl-D). Ctrl-C will terminate the process.
            _ = try? channel.close().wait()
            try? group.syncShutdownGracefully()
        } else {
            print("NIOTSEchoClient requires macOS 10.14+, iOS 12+, tvOS 12+ and watchOS 6+.")
        }
    }
}

#else

@main
struct NIOTSEchoClientUnsupportedPlatform {
    static func main() {
        print("NIOTSEchoClient requires Network.framework (Apple platforms). On Linux, use swift-nio UDP instead.")
    }
}

#endif
