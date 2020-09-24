# NIO Transport Services

Extensions for [SwiftNIO](https://github.com/apple/swift-nio) to support Apple platforms as first-class citizens.

## About NIO Transport Services

NIO Transport Services is an extension to SwiftNIO that provides first-class support for Apple platforms by using [Network.framework](https://developer.apple.com/documentation/network) to provide network connectivity, and [Dispatch](https://developer.apple.com/documentation/dispatch) to provide concurrency. NIOTS provides an alternative [EventLoop](https://apple.github.io/swift-nio/docs/current/NIO/Protocols/EventLoop.html), [EventLoopGroup](https://apple.github.io/swift-nio/docs/current/NIO/Protocols/EventLoopGroup.html), and several alternative [Channels](https://apple.github.io/swift-nio/docs/current/NIO/Protocols/Channel.html) and Bootstraps.

In addition to providing first-class support for Apple platforms, NIO Transport Services takes advantage of the richer API of Network.framework to provide more insight into the behaviour of the network than is normally available to NIO applications. This includes the ability to wait for connectivity until a network route is available, as well as all of the extra proxy and VPN support that is built directly into Network.framework.

All regular NIO applications should work just fine with NIO Transport Services, simply by changing the event loops and bootstraps in use.

## Why Transport Services?

Network.framework is Apple's reference implementation of the [proposed post-sockets API](https://datatracker.ietf.org/wg/taps/charter/) that is currently being worked on by the Transport Services Working Group (taps) of the IETF. To indicate the proposed long-term future of interfaces like Network.framework, we decided to call this module NIOTransportServices. Also, NIONetworkFramework didn't appeal to us much as a name.

## How to Use?

NIO Transport Services primarily uses SwiftPM as its build tool, so we recommend using that as well. If you want to depend on NIO Transport Services in your own project, it's as simple as adding a dependencies clause to your Package.swift:

```
dependencies: [
    .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.1.1")
]
```

and then adding the NIOTransportServices module to your target dependencies.

If your project is set up as an Xcode project and you're using Xcode 11+, you can add NIO Transport Services as a dependency to your Xcode project by clicking File -> Swift Packages -> Add Package Dependency. In the upcoming dialog, please enter `https://github.com/apple/swift-nio-transport-services.git` and click Next twice. Finally, make sure `NIOTransportServices` is selected and click finish. Now will be able to `import NIOTransportServices` in your project.

You can also use SwiftNIO Transport Services in an iOS project through CocoaPods:

    pod 'SwiftNIO', '~> 2.0.0'
    pod 'SwiftNIOTransportServices', '~> 1.0.0'

If you want to develop SwiftNIO with Xcode 10, you have to generate an Xcode project:

```
swift package generate-xcodeproj
```

and add the project as a sub-project by dragging it into your iOS project and adding the framework (`NIOTransportServices.framework`) in 'Build Phases' -> 'Link Binary Libraries'.

Do note however that Network.framework requires macOS 10.14+, iOS 12+, or tvOS 12+.

### Supported Platforms

NIOTransportServices is supported where Network.framework is supported: macOS
10.14+, iOS 12+, tvOS 12+, and watchOS 6+.

In order to allow dependencies to use NIOTransportServices when it's available
and fallback to NIO when it isn't, all code is behind import guards checking
the availability of Network.framework. As such NIOTransportServices may be
built on platforms where Network.framework is *not* available.
NIOTransportServices can be built on macOS 10.12+, iOS 10+, tvOS 10+, watchOS
6+ and Linux but is only functionally useful on macOS 10.14+, iOS 12+, tvOS 12+
and watchOS 6+.

## Versioning

Just like the rest of the SwiftNIO family, `swift-nio-transport-services` follows [SemVer 2.0.0](https://semver.org/#semantic-versioning-200) with a separate document
declaring [SwiftNIO's Public API](https://github.com/apple/swift-nio/blob/main/docs/public-api.md).

### `swift-nio-transport-services ` 1.x

`swift-nio-transport-services ` versions 1.x is part of the SwiftNIO 2 family of repositories and does not have any dependencies besides [`swift-nio`](https://github.com/apple/swift-nio), Swift 5, and an Apple OS supporting `Network.framework`. As the latest version, it lives on the [`main`](https://github.com/apple/swift-nio-transport-services) branch.

To depend on `swift-nio-transport-services `, put the following in the `dependencies` of your `Package.swift`:

    .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.0.0"),

### `swift-nio-transport-services ` 0.x

The legacy `swift-nio-transport-services` 0.x is part of the SwiftNIO 1 family of repositories and works with Swift 4.1 and newer. The source code can be found on the [`swift-nio-transport-services-swift-4-maintenance`](https://github.com/apple/swift-nio-transport-services/tree/swift-nio-transport-services-swift-4-maintenance) branch.

## Developing NIO Transport Services

For the most part, NIO Transport Services development is as straightforward as any other SwiftPM project. With that said, we do have a few processes that are worth understanding before you contribute. For details, please see `CONTRIBUTING.md` in this repository.

Please note that all work on NIO Transport Services is covered by the [SwiftNIO Code of Conduct](https://github.com/apple/swift-nio/blob/main/CODE_OF_CONDUCT.md).

