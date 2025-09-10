//===----------------------------------------------------------------------===//
// This test isolates a NIOTS UDP client talking to a POSIX UDP echo server.
// It sends two datagrams: "hello" and "world". The first echo is asserted
// strictly. The second echo is wrapped in XCTExpectFailure to expose the
// suspected NIOTS "one‑shot" close/drop after the first round‑trip.
//===----------------------------------------------------------------------===//

//    How to run just this test
//
//    - From the swift-nio-transport-services repo root:
//    - swift test -v --filter NIOTransportServicesTests/NIOTSUDPMultiDatagramsPOSIXServerTests.testNIOTSClient_POSIXServer_MultipleDatagrams_expectedFailure


#if canImport(Network)
import XCTest
import NIOCore
import NIOPosix
import NIOTransportServices

private final class POSIXUDPEchoHandler: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = self.unwrapInboundIn(data)
        context.write(self.wrapOutboundOut(envelope), promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Keep the server simple; close on error
        context.close(promise: nil)
    }
}

private final class ClientCaptureHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let onRead: (String) -> Void
    init(onRead: @escaping (String) -> Void) { self.onRead = onRead }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = self.unwrapInboundIn(data)
        let s = buf.readString(length: buf.readableBytes) ?? ""
        // print("[client] read:", s)
        self.onRead(s)
    }
}

// Debug probe (disabled for upstream submission)
// private final class LifecycleProbeHandler: ChannelInboundHandler {
//     typealias InboundIn = Any
//     private let tag: String
//     init(tag: String) { self.tag = tag }
//     func handlerAdded(context: ChannelHandlerContext) { print("[\(tag)] handlerAdded") }
//     func channelActive(context: ChannelHandlerContext) { print("[\(tag)] channelActive"); context.fireChannelActive() }
//     func channelInactive(context: ChannelHandlerContext) { print("[\(tag)] channelInactive"); context.fireChannelInactive() }
//     func errorCaught(context: ChannelHandlerContext, error: Error) { print("[\(tag)] errorCaught: \(error)"); context.fireErrorCaught(error) }
// }

private final class UDPClientActiveHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    private let activePromise: EventLoopPromise<Void>
    init(_ p: EventLoopPromise<Void>) { self.activePromise = p }
    func channelActive(context: ChannelHandlerContext) {
        self.activePromise.succeed(())
        context.fireChannelActive()
    }
}

final class NIOTSUDPMultiDatagramsPOSIXServerTests: XCTestCase {
    // Reproducer for suspected NIOTS connected‑UDP “one‑shot” close.
    // After the first datagram round‑trip, the NIOTS datagram channel may close,
    // causing subsequent datagrams to fail or never be echoed. This test uses a
    // stable POSIX UDP echo server and a NIOTS UDP client to isolate the issue.
    //
    // How to run only this test:
    // swift test -v --filter NIOTransportServicesTests/NIOTSUDPMultiDatagramsPOSIXServerTests.testNIOTSClient_POSIXServer_MultipleDatagrams_expectedFailure
    //
    // Expected behavior:
    // - First echo ("hello") succeeds.
    // - Second echo ("world") times out; wrapped in XCTExpectFailure so CI stays green.
    //
    // Xcode (symbolic breakpoint)
    //
    // - Open the Breakpoint Navigator.
    // - Click + → Add Symbolic Breakpoint…
    // - Symbol: nw_connection_cancel
    // - (Optional) Add Action: debugger command bt
    // - Run your test; Xcode will break when NIOTS cancels the NWConnection.
    //
    // Optional LLDB steps (Xcode):
    // 1) Add a Symbolic Breakpoint: br s -n nw_connection_cancel
    // 2) Run this test; when it breaks, run `bt` in the debugger.
    // 3) Typical call chain observed after the first echoed datagram:
    //
    //    StateManagedNWConnectionChannel.dataReceivedHandler(content=<N bytes>, isComplete=true, error=nil)
    //    → didReadEOF()
    //    → StateManagedChannel.close0(error=eof)
    //    → nw_connection_cancel
    //
    //    Note error=nil: the close is triggered solely because isComplete was true.
    func testNIOTSClient_POSIXServer_MultipleDatagrams_expectedFailure() throws {
        // POSIX UDP echo server
        let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try serverGroup.syncShutdownGracefully()) }

        let server = try DatagramBootstrap(group: serverGroup)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandler(POSIXUDPEchoHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        defer { XCTAssertNoThrow(try server.close().wait()) }

        guard let port = server.localAddress?.port else {
            XCTFail("No server port")
            return
        }

        // NIOTS connected UDP client
        let clientGroup = NIOTSEventLoopGroup(loopCount: 1)
        defer { XCTAssertNoThrow(try clientGroup.syncShutdownGracefully()) }

        let gotHello = expectation(description: "got hello")
        let gotWorld = expectation(description: "got world")

        let clientActive = clientGroup.next().makePromise(of: Void.self)
        let client = try NIOTSDatagramConnectionBootstrap(group: clientGroup)
            .channelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    // Debug probe disabled to keep the test minimal for upstream submission.
                    // try ch.pipeline.syncOperations.addHandler(LifecycleProbeHandler(tag: "client"))
                    try ch.pipeline.syncOperations.addHandler(UDPClientActiveHandler(clientActive))
                    try ch.pipeline.syncOperations.addHandler(ClientCaptureHandler { text in
                        if text == "hello" { gotHello.fulfill() }
                        if text == "world" { gotWorld.fulfill() }
                    })
                }
            }
            .connect(host: "127.0.0.1", port: port)
            .wait()
        
        defer { _ = try? client.close().wait() }

        // Avoid early write before active
        XCTAssertNoThrow(try clientActive.futureResult.wait())

        // First datagram: expect echo strictly
        var hello = client.allocator.buffer(capacity: 5); hello.writeString("hello")
        XCTAssertNoThrow(try client.writeAndFlush(hello).wait())
        wait(for: [gotHello], timeout: 1.0)

        // Second datagram: expose suspected NIOTS one‑shot behavior
        var world = client.allocator.buffer(capacity: 5); world.writeString("world")
        XCTExpectFailure("NIOTS may close connected UDP after first datagram (one‑shot). Second echo may be lost. Tracking: https://github.com/apple/swift-nio-transport-services/issues/XXXX") {
            _ = try? client.writeAndFlush(world).wait()
            wait(for: [gotWorld], timeout: 0.75)
        }
    }
}
#endif
