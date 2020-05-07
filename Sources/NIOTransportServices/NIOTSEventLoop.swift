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
import Dispatch
import Foundation
import Network

import NIO
import NIOConcurrencyHelpers

/// An `EventLoop` that interacts with `DispatchQoS` to help schedule upcoming work.
///
/// `EventLoop`s that implement `QoSEventLoop` can interact with `Dispatch` to propagate information
/// about the QoS required for a specific task block. This allows tasks to be dispatched onto an
/// event loop with a different priority than the majority of tasks on that loop.
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
public protocol QoSEventLoop: EventLoop {
    /// Submit a given task to be executed by the `EventLoop` at a given `qos`.
    func execute(qos: DispatchQoS, _ task: @escaping () -> Void) -> Void

    /// Schedule a `task` that is executed by this `NIOTSEventLoop` after the given amount of time at the
    /// given `qos`.
    func scheduleTask<T>(in time: TimeAmount, qos: DispatchQoS, _ task: @escaping () throws -> T) -> Scheduled<T>
}


/// The lifecycle state of a given event loop.
///
/// Event loops have the ability to be shut down, and not restarted. When a loop is active it will accept
/// new registrations, and new scheduled work items. When a loop is shutting down it will no longer accept
/// new registrations, but it will continue to accept new scheduled work items. When a loop is closed, it
/// will accept neither new registrations nor new scheduled work items, but it will continue to process
/// the queue until it has drained.
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
fileprivate enum LifecycleState {
    case active
    case closing
    case closed
}

/// Reports a fatal error in the same manner as `preconditionFailure(_:file:line:)`. Requires Swift private API
/// via `SwiftShims`. Used in `preconditionInEventLoop(_:file:line:)` and `preconditionNotInEventLoop(_:file:line:)`.
/// This will almost definitely be removed before merging.
#if !USE_PUBLIC_API_ONLY
import SwiftShims

fileprivate func stdlibPrivate_reportFatalErrorInFile(prefix: StaticString, message: String, file: StaticString, line: UInt) {
    var mmessage = message
    
    prefix.withUTF8Buffer { prefix in
        mmessage.withUTF8 { message in
            file.withUTF8Buffer { file in
                _swift_stdlib_reportFatalErrorInFile(
                    prefix.baseAddress!, CInt(prefix.count),
                    message.baseAddress!, CInt(message.count),
                    file.baseAddress!, CInt(file.count),
                    UInt32(line),
                    UInt32(_isDebugAssertConfiguration() ? 1 : 0)
                )
            }
        }
    }
}
#endif

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
internal class NIOTSEventLoop: QoSEventLoop {
    private let loop: DispatchQueue
    private let taskQueue: DispatchQueue
    private let inQueueKey: DispatchSpecificKey<UUID>
    private let loopID: UUID
    private let defaultQoS: DispatchQoS

    /// All the channels registered to this event loop.
    ///
    /// This array does two jobs. Firstly, it ensures that these channels stay alive for as long as
    /// they are registered: they cannot leak. Secondly, it provides a notification mechanism for
    /// this event loop to deliver them specific kinds of events: in particular, to request that
    /// they quiesce or shut themselves down.
    private var registeredChannels: [ObjectIdentifier: Channel] = [:]

    /// The state of this event loop.
    private var state = LifecycleState.active

    /// Whether this event loop is accepting new channels.
    private var open: Bool {
        return self.state == .active
    }

    /// Returns whether the currently executing code is on the event loop.
    ///
    /// Due to limitations in Dispatch's API, this check is pessimistic: there are circumstances where a perfect
    /// implementation *could* return `true`, but this version will be unable to prove that and will return `false`.
    /// If you need to write an assertion about being in the event loop that must be correct, use SwiftNIO 1.11 or
    /// later and call `preconditionInEventLoop` and `assertInEventLoop`.
    public var inEventLoop: Bool {
        return DispatchQueue.getSpecific(key: self.inQueueKey) == self.loopID
    }

    public init(qos: DispatchQoS) {
        self.loop = DispatchQueue(label: "nio.transportservices.eventloop.loop", qos: qos, autoreleaseFrequency: .workItem)
        self.taskQueue = DispatchQueue(label: "nio.transportservices.eventloop.taskqueue", target: self.loop)
        self.loopID = UUID()
        self.inQueueKey = DispatchSpecificKey()
        self.defaultQoS = qos
        loop.setSpecific(key: inQueueKey, value: self.loopID)
    }

    public func execute(_ task: @escaping () -> Void) {
        self.execute(qos: self.defaultQoS, task)
    }

    public func execute(qos: DispatchQoS, _ task: @escaping () -> Void) {
        // Ideally we'd not accept new work while closed. Sadly, that's not possible with the current APIs for this.
        self.taskQueue.async(qos: qos, execute: task)
    }

    public func scheduleTask<T>(deadline: NIODeadline, _ task: @escaping () throws -> T) -> Scheduled<T> {
        return self.scheduleTask(deadline: deadline, qos: self.defaultQoS, task)
    }

    public func scheduleTask<T>(deadline: NIODeadline, qos: DispatchQoS, _ task: @escaping () throws -> T) -> Scheduled<T> {
        let p: EventLoopPromise<T> = self.makePromise()

        guard self.state != .closed else {
            p.fail(EventLoopError.shutdown)
            return Scheduled(promise: p, cancellationTask: { } )
        }

        // Dispatch support for cancellation exists at the work-item level, so we explicitly create one here.
        // We set the QoS on this work item and explicitly enforce it when the block runs.
        let timerSource = DispatchSource.makeTimerSource(queue: self.taskQueue)
        timerSource.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline.uptimeNanoseconds))
        timerSource.setEventHandler(qos: qos, flags: .enforceQoS) {
            do {
                p.succeed(try task())
            } catch {
                p.fail(error)
            }
        }
        timerSource.resume()

        return Scheduled(promise: p, cancellationTask: {
            timerSource.cancel()
        })
    }

    public func scheduleTask<T>(in time: TimeAmount, _ task: @escaping () throws -> T) -> Scheduled<T> {
        return self.scheduleTask(in: time, qos: self.defaultQoS, task)
    }

    public func scheduleTask<T>(in time: TimeAmount, qos: DispatchQoS, _ task: @escaping () throws -> T) -> Scheduled<T> {
        return self.scheduleTask(deadline: NIODeadline.now() + time, qos: qos, task)
    }

    public func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        self.closeGently().map {
            queue.async { callback(nil) }
        }.whenFailure { error in
            queue.async { callback(error) }
        }
    }

    func preconditionInEventLoop(file: StaticString, line: UInt) {
        // Do not forward to the other overload.
        dispatchPrecondition(condition: .onQueue(self.loop))
    }

    func preconditionInEventLoop(_ message: @autoclosure() -> String, file: StaticString, line: UInt) {
        /// There are several problems complicating this otherwise simple method:
        ///
        ///  - There's no way to hook into `dispatchPrecondition(condition:)` failures, so there's no way to
        ///    output a message on failure before the process crashes.
        ///
        ///  - There are esoteric ways of interrupting the process crashing, such as a fatal signal handler,
        ///    but none of them are safe or play well with user code.
        ///
        ///  - We can't just ignore the `message`. For example, in `EventLoopFuture.wait()`, the precondition comes
        ///    with a clear and immediate explanation of what went wrong. This explanation is invaluable to coders
        ///    still learning how futures and event loops work, but it can't help if it's discarded.
        ///
        ///  - The value of `self.inEventLoop` is documented as unreliable. Specifically, there is an apparent
        ///    risk of inccorect `false` values, which would cause the precondition to trigger when it shouldn't.
        ///
        ///  - It is possible to submit a carefully constructed task to an appropriate choice of event loop and await
        ///    a result that will determine whether or not the caller is running in the event loop. But, the code to
        ///    do it would be very convoluted and very easy to break by accident. It would also be very slow, incurring
        ///    at least two context switches just as a start. Given that this code remains active in release builds, the
        ///    speed cost would be unacceptable even if the implementation was perfect.
        ///
        /// At the time of this writing, it's uncear what the best solution is, or if there is one at all. It would
        /// be extremely helpful to obtain a more complete understanding of exactly how and why `inEventLoop`'s
        /// behavior is unreliable.
        ///
        /// For now, in order to produce a first draft, this implementation assumes (pretends?) that `inEventLoop` is
        /// accurate and treats its value as definitive. The value determines whether or not the provided message (if
        /// any) is reported. Either way, an appropriate `dispatchPrecondition(condition:)` call follows afterwards
        /// so the process continues or terminates correctly even if the flag was wrong after all. The behavior in that
        /// case will be a spurious message referring to a failure that didn't happen. This won't be acceptable as a
        /// final implementation but it works fine as a first draft.
        precondition({
            if !self.inEventLoop {
                let msg = message()

                // Ideally, we'd like mimic `preconditionFailure()` as much as possible. Unfortunately, this is
                // impossible to accomplish using public API without also terminating the process. Two solutions
                // are shown here:
                #if USE_PUBLIC_API_ONLY
                    /// In the API-only case, just accept it's not gonna be a real "fatal error" and print to stderr.
                    /// Not that calling `write(2)` like this is really so great either, but at least it's simple. It
                    /// can be improved upon as needed.
                    let output = "Precondition failure: \(msg)\(msg.isEmpty ? "" : ": ")file \(file), line \(line)\n"
                    
                    write(STDERR_FILENO, output, output.utf8.count)
                #else
                    /// If private API is allowed, pretty much just copy how `preconditionFailure(_:file:line:)` works,
                    /// minus the "crash this process" part at the end.
                    /// See `stdlibPrivate_reportFatalErrorInFile(prefix:message:file:line:)` above for more details.
                    stdlibPrivate_reportFatalErrorInFile(prefix: "Precondition failure", message: msg, file: file, line: line)
                #endif
            }
            return true
        }())
        dispatchPrecondition(condition: .onQueue(self.loop))
    }

    func preconditionNotInEventLoop(_ message: @autoclosure() -> String = "", file: StaticString, line: UInt) {
        /// Refer to the detailed remarks immediately above in `preconditionInEventLoop(_:file:line:)`
        /// for background information and contextual detail on this implementation.
        ///
        /// Additional note: In the case of this method, instead of a spurious erorr message if the `inEventLoop`
        /// flag is wrong, there will be a spurious _lack_ of an error message. This is even less acceptable,
        /// obviously, but again, it will work as a first draft.
        precondition({
            if self.inEventLoop {
                let msg = message()
                #if USE_PUBLIC_API_ONLY
                    let output = "Precondition failure: \(msg)\(msg.isEmpty ? "" : ": ")file \(file), line \(line)\n"
                    write(STDERR_FILENO, output, output.utf8.count)
                #else
                    stdlibPrivate_reportFatalErrorInFile(prefix: "Precondition failure", message: msg, file: file, line: line)
                #endif
            }
            return true
        }())
        dispatchPrecondition(condition: .notOnQueue(self.loop))
    }
}

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension NIOTSEventLoop {
    /// Create a `DispatchQueue` to use for events on a given `Channel`.
    ///
    /// This `DispatchQueue` will be guaranteed to execute on this `EventLoop`, and
    /// so is safe to use concurrently with the rest of the event loop.
    internal func channelQueue(label: String, qos: DispatchQoS? = nil) -> DispatchQueue {
        // If a QoS override is not requested, use the default.
        let qos = qos ?? self.defaultQoS
        return DispatchQueue(label: label, qos: qos, target: self.loop)
    }
}

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension NIOTSEventLoop {
    internal func closeGently() -> EventLoopFuture<Void> {
        let p: EventLoopPromise<Void> = self.makePromise()
        self.taskQueue.async {
            guard self.open else {
                p.fail(EventLoopError.shutdown)
                return
            }

            // Ok, time to shut down.
            self.state = .closing

            // We need to tell all currently-registered channels to close.
            let futures: [EventLoopFuture<Void>] = self.registeredChannels.map { _, channel in
                channel.close(promise: nil)
                return channel.closeFuture.flatMapErrorThrowing { error in
                    if let error = error as? ChannelError, error == .alreadyClosed {
                        return ()
                    } else {
                        throw error
                    }
                }
            }

            // The ordering here is important.
            // We must not transition into the closed state until *after* the caller has been notified that the
            // event loop is closed. Otherwise, this future is in real trouble, as if it needs to dispatch onto the
            // event loop it will be forbidden from doing so.
            let completionFuture = EventLoopFuture<Void>.andAllComplete(futures, on: self)
            completionFuture.cascade(to: p)
            completionFuture.whenComplete { (_: Result<Void, Error>) in
                self.state = .closed
            }
        }
        return p.futureResult
    }
}

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension NIOTSEventLoop {
    /// Record a given channel with this event loop.
    internal func register(_ channel: Channel) throws {
        guard self.open else {
            throw EventLoopError.shutdown
        }

        channel.eventLoop.assertInEventLoop()
        self.registeredChannels[ObjectIdentifier(channel)] = channel
    }

    // We don't allow deregister to fail, as it doesn't make any sense.
    internal func deregister(_ channel: Channel) {
        channel.eventLoop.assertInEventLoop()
        let oldChannel = self.registeredChannels.removeValue(forKey: ObjectIdentifier(channel))
        assert(oldChannel != nil)
    }
}
#endif
