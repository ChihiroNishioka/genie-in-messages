// swift-tools-version:5.10
import PackageDescription

var products: [Product] = [
    .library(name: "GenieCore", targets: ["GenieCore"]),
]
var targets: [Target] = [
    .target(name: "GenieCore"),
    .testTarget(
        name: "GenieCoreTests",
        dependencies: ["GenieCore"],
        exclude: ["Fixtures"]
    ),
]

#if os(macOS)
products.append(.executable(name: "GenieMenuBar", targets: ["GenieMenuBar"]))
targets.append(
    .executableTarget(
        name: "GenieMenuBar",
        dependencies: ["GenieCore"],
        linkerSettings: [
            .linkedFramework("CoreGraphics"),
        ]
    )
)
let packagePlatforms: [SupportedPlatform]? = [.macOS(.v14)]
#else
let packagePlatforms: [SupportedPlatform]? = nil
#endif

let package = Package(
    name: "genie-in-messages",
    platforms: packagePlatforms,
    products: products,
    targets: targets
)
