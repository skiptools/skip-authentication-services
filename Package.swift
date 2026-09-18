// swift-tools-version: 6.1
// This is a Skip (https://skip.dev) package.
import PackageDescription

let package = Package(
    name: "skip-authentication-services",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SkipAuthenticationServices", type: .dynamic, targets: ["SkipAuthenticationServices"]),
    ],
    dependencies: [
        .package(url: "https://github.com/skiptools/skip.git", from: "1.8.4"),
        .package(url: "https://github.com/skiptools/skip-ui.git", from: "1.51.0")
    ],
    targets: [
        .target(name: "SkipAuthenticationServices", dependencies: [
            .product(name: "SkipUI", package: "skip-ui")
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .testTarget(name: "SkipAuthenticationServicesTests", dependencies: [
            "SkipAuthenticationServices",
            .product(name: "SkipTest", package: "skip")
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
    ]
)

// SKIP_DYNAMIC_LIBRARIES and SKIP_BRIDGE both enforce building as dynamic
// libraries; SKIP_BRIDGE additionally puts the skipstone plugin in bridge mode
let bridgeMode = (Context.environment["SKIP_BRIDGE"] ?? "0") != "0"
let forceDylib = bridgeMode || (Context.environment["SKIP_DYNAMIC_LIBRARIES"] ?? "0") != "0"

if bridgeMode {
    package.dependencies += [.package(url: "https://github.com/skiptools/skip-fuse-ui.git", from: "1.0.0")]
    package.targets.forEach({ target in
        target.dependencies += [
            .product(name: "SkipFuseUI", package: "skip-fuse-ui"),
            .product(name: "SkipSwiftUI", package: "skip-fuse-ui"),
        ]
    })
}

if forceDylib {
    // all library types must be dynamic to support bridging
    package.products = package.products.map({ product in
        guard let libraryProduct = product as? Product.Library else { return product }
        return .library(name: libraryProduct.name, type: .dynamic, targets: libraryProduct.targets)
    })
}
