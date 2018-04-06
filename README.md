# NIO Transport Services

Extensions for [SwiftNIO](https://github.com/apple/swift-nio) to support Apple platforms as first-class citizens.

## About NIO Transport Services

NIO Transport Services is an extension to SwiftNIO that provides first-class support for Apple platforms by using [Network.framework](https://developer.apple.com/documentation/network) to provide network connectivity, and [Dispatch](https://developer.apple.com/documentation/dispatch) to provide concurrency. NIOTS provides an alternative [EventLoop](https://apple.github.io/swift-nio/docs/current/NIO/Protocols/EventLoop.html), [EventLoopGroup](https://apple.github.io/swift-nio/docs/current/NIO/Protocols/EventLoopGroup.html), and several alternative [Channels](https://apple.github.io/swift-nio/docs/current/NIO/Protocols/Channel.html) and Bootstraps.

In addition to providing first-class support for Apple platforms, NIO Transport Services takes advantage of the richer API of Network.framework to provide more insight into the behaviour of the network than is normally available to NIO applications. This includes the ability to wait for connectivity until a network route is available, as well as all of the extra proxy and VPN support that is built directly into Network.framework.

All regular NIO applications should work just fine with NIO Transport Services, simply by changing the event loops and bootstraps in use.

## Why Transport Services?

Network.framework is Apple's reference implementation of the [proposed post-sockets API](https://datatracker.ietf.org/wg/taps/charter/) that is currently being worked on by the Transport Services Working Group (taps) of the IETF. To indicate the proposed long-term future of interfaces like Network.framework, we decided to call this module NIOTransportServices. Also, NIONetworkFramework didn't appeal to us much as a name.

## Limitations

Network.framework is only available on macOS 10.14+, iOS 12+, and tvOS 12+. This does not match the current minimum deployment target for Swift Package Manager, so building this repository with Swift Package Manager requires that you pass custom build flags, e.g:

```
swift build -Xswiftc -target -Xswiftc x86_64-apple-macosx10.14
```

Alternatively, if you want to use Xcode to build this repository, you can use the following xcconfig:

```
MACOSX_DEPLOYMENT_TARGET = 10.14
```

For support in iOS or tvOS, change the targets as necessary.

## Versioning

This repository will remain in development throughout the beta period of macOS Mojave and iOS 12. Once those operating systems have gone GM, we will finalize the API and cut a stable release.

## Developing NIO Transport Services

For the most part, NIO Transport Services development is as straightforward as any other SwiftPM project. With that said, we do have a few processes that are worth understanding before you contribute. For details, please see `CONTRIBUTING.md` in this repository.

Please note that all work on NIO Transport Services is covered by the [SwiftNIO Code of Conduct](https://github.com/apple/swift-nio/blob/master/CODE_OF_CONDUCT.md).

