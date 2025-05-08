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
import Dispatch
import NIOCore

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension NIOTSEventLoopGroup {
    /// A globally shared, lazily initialized, singleton ``NIOTSEventLoopGroup``.
    ///
    /// SwiftNIO allows and encourages the precise management of all operating system resources such as threads and file descriptors.
    /// Certain resources (such as the main `EventLoopGroup`) however are usually globally shared across the program. This means
    /// that many programs have to carry around an `EventLoopGroup` despite the fact they don't require the ability to fully return
    /// all the operating resources which would imply shutting down the `EventLoopGroup`. This type is the global handle for singleton
    /// resources that applications (and some libraries) can use to obtain never-shut-down singleton resources.
    ///
    /// Programs and libraries that do not use these singletons will not incur extra resource usage, these resources are lazily initialized on
    /// first use.
    ///
    /// The loop count of this group is determined by `NIOSingletons.groupLoopCountSuggestion`.
    ///
    /// - note: Users who do not want any code to spawn global singleton resources may set
    ///         `NIOSingletons.singletonsEnabledSuggestion` to `false` which will lead to a forced crash
    ///         if any code attempts to use the global singletons.
    public static var singleton: NIOTSEventLoopGroup {
        NIOSingletons.transportServicesEventLoopGroup
    }
}

// swift-format-ignore: DontRepeatTypeInStaticProperties
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension EventLoopGroup where Self == NIOTSEventLoopGroup {
    /// A globally shared, lazily initialized, singleton ``NIOTSEventLoopGroup``.
    ///
    /// This provides the same object as ``NIOTSEventLoopGroup/singleton``.
    public static var singletonNIOTSEventLoopGroup: Self {
        NIOTSEventLoopGroup.singleton
    }
}

extension NIOSingletons {
    /// A globally shared, lazily initialized, singleton ``NIOTSEventLoopGroup``.
    ///
    /// SwiftNIO allows and encourages the precise management of all operating system resources such as threads and file descriptors.
    /// Certain resources (such as the main `EventLoopGroup`) however are usually globally shared across the program. This means
    /// that many programs have to carry around an `EventLoopGroup` despite the fact they don't require the ability to fully return
    /// all the operating resources which would imply shutting down the `EventLoopGroup`. This type is the global handle for singleton
    /// resources that applications (and some libraries) can use to obtain never-shut-down singleton resources.
    ///
    /// Programs and libraries that do not use these singletons will not incur extra resource usage, these resources are lazily initialized on
    /// first use.
    ///
    /// The loop count of this group is determined by `NIOSingletons.groupLoopCountSuggestion`.
    ///
    /// - note: Users who do not want any code to spawn global singleton resources may set
    ///         `NIOSingletons.singletonsEnabledSuggestion` to `false` which will lead to a forced crash
    ///         if any code attempts to use the global singletons.
    @available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
    public static var transportServicesEventLoopGroup: NIOTSEventLoopGroup {
        globalTransportServicesEventLoopGroup
    }
}

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
private let globalTransportServicesEventLoopGroup: NIOTSEventLoopGroup = {
    guard NIOSingletons.singletonsEnabledSuggestion else {
        fatalError(
            """
            Cannot create global singleton NIOThreadPool because the global singletons have been \
            disabled by setting `NIOSingletons.singletonsEnabledSuggestion = false`
            """
        )
    }

    let group = NIOTSEventLoopGroup._makePerpetualGroup(
        loopCount: NIOSingletons.groupLoopCountSuggestion,
        defaultQoS: .default
    )
    _ = Unmanaged.passUnretained(group).retain()  // Never gonna give you up, never gonna let you down.
    return group
}()
#endif
