// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyTagsKit",
    // `.v26` needs tools 6.2; the string form keeps the manifest at tools 6.0.
    platforms: [.iOS("26.0"), .macOS(.v15)],
    products: [
        .library(name: "MyTagsKit", targets: ["MyTagsKit"]),
    ],
    targets: [
        .target(name: "MyTagsKit"),
        .testTarget(name: "MyTagsKitTests", dependencies: ["MyTagsKit"]),
    ],
    swiftLanguageModes: [.v6]
)
