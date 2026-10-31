// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "RemoteAgent", platforms: [.macOS(.v14)], products: [
    .executable(name: "RemoteAgent", targets: ["RemoteAgentApp"]),
    .executable(name: "RemoteAgentWorker", targets: ["RemoteAgentWorker"]),
    .library(name: "RemoteAgentService", targets: ["RemoteAgentService"])
], dependencies: [
    .package(path: "../ServiceKit"),
    .package(path: "../Decomposer/Packages/HarnessCore"),
    .package(path: "../Decomposer/Packages/HarnessMLX"),
    .package(url: "https://github.com/apple/swift-nio", exact: "2.89.0")
], targets: [
    .target(name: "RemoteAgentService", dependencies: [.product(name: "ServiceKit", package: "ServiceKit"),.product(name: "HarnessCore", package: "HarnessCore"), .product(name: "NIOPosix", package: "swift-nio"), .product(name: "NIOHTTP1", package: "swift-nio"), .product(name: "NIOCore", package: "swift-nio")]),
    .executableTarget(name: "RemoteAgentApp", dependencies: [.product(name: "ServiceKit", package: "ServiceKit"), "RemoteAgentService", .product(name: "HarnessCore", package: "HarnessCore")]),
    .executableTarget(name: "RemoteAgentWorker", dependencies: [.product(name: "HarnessMLX", package: "HarnessMLX"), .product(name: "HarnessCore", package: "HarnessCore")]),
    .testTarget(name: "RemoteAgentTests", dependencies: ["RemoteAgentService", .product(name: "HarnessCore", package: "HarnessCore")])
], swiftLanguageModes: [.v5])
