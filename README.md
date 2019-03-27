# NIO Transport Services

Extensions for [SwiftNIO](https://github.com/apple/swift-nio) to support Apple platforms as first-class citizens.

## About NIO Transport Services

NIO Transport Services is an extension to SwiftNIO that provides first-class support for Apple platforms by using [Network.framework](https://developer.apple.com/documentation/network) to provide network connectivity, and [Dispatch](https://developer.apple.com/documentation/dispatch) to provide concurrency. NIOTS provides an alternative [EventLoop](https://apple.github.io/swift-nio/docs/current/NIO/Protocols/EventLoop.html), [EventLoopGroup](https://apple.github.io/swift-nio/docs/current/NIO/Protocols/EventLoopGroup.html), and several alternative [Channels](https://apple.github.io/swift-nio/docs/current/NIO/Protocols/Channel.html) and Bootstraps.

In addition to providing first-class support for Apple platforms, NIO Transport Services takes advantage of the richer API of Network.framework to provide more insight into the behaviour of the network than is normally available to NIO applications. This includes the ability to wait for connectivity until a network route is available, as well as all of the extra proxy and VPN support that is built directly into Network.framework.

All regular NIO applications should work just fine with NIO Transport Services, simply by changing the event loops and bootstraps in use.

## Why Transport Services?

Network.framework is Apple's reference implementation of the [proposed post-sockets API](https://datatracker.ietf.org/wg/taps/charter/) that is currently being worked on by the Transport Services Working Group (taps) of the IETF. To indicate the proposed long-term future of interfaces like Network.framework, we decided to call this module NIOTransportServices. Also, NIONetworkFramework didn't appeal to us much as a name.

## How to Use?

Today, the easiest way to use SwiftNIO Transport Services in an iOS project is through CocoaPods:

    pod 'SwiftNIO', '~> 2.0.0'
    pod 'SwiftNIOTransportServices', '~> 1.0.0'

You can also use the Swift Package Manager:

```
swift build
```

and add the project as a sub-project by dragging it into your iOS project and adding the frameworks (such as `NIO.framework`) in 'Build Phases' -> 'Link Binary Libraries'.

Do note however that Network.framework requires macOS 10.14+, iOS 12+, or tvOS 12+.


## Versioning

Just like the rest of the SwiftNIO family, `swift-nio-transport-services` follows [SemVer 2.0.0](https://semver.org/#semantic-versioning-200) with a separate document
declaring [SwiftNIO's Public API](https://github.com/apple/swift-nio/blob/master/docs/public-api.md).

### `swift-nio-transport-services ` 1.x

`swift-nio-transport-services ` versions 1.x is part of the SwiftNIO 2 family of repositories and does not have any dependencies besides [`swift-nio`](https://github.com/apple/swift-nio), Swift 5, and an Apple OS supporting `Network.framework`. As the latest version, it lives on the [`master`](https://github.com/apple/swift-nio-transport-services) branch.

To depend on `swift-nio-transport-services `, put the following in the `dependencies` of your `Package.swift`:

    .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.0.0"),

### `swift-nio-transport-services ` 0.x

The legacy `swift-nio-transport-services` 0.x is part of the SwiftNIO 1 family of repositories and works with Swift 4.1 and newer. The source code can be found on the [`swift-nio-transport-services-swift-4-maintenance`](https://github.com/apple/swift-nio-transport-services/tree/swift-nio-transport-services-swift-4-maintenance) branch.

## Developing NIO Transport Services

For the most part, NIO Transport Services development is as straightforward as any other SwiftPM project. With that said, we do have a few processes that are worth understanding before you contribute. For details, please see `CONTRIBUTING.md` in this repository.

Please note that all work on NIO Transport Services is covered by the [SwiftNIO Code of Conduct](https://github.com/apple/swift-nio/blob/master/CODE_OF_CONDUCT.md).

