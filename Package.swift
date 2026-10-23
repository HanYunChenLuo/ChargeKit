// swift-tools-version:6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "ChargeKit",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "SMCKit",
            path: "Sources/SMCKit",
            swiftSettings: v5
        ),
        .target(
            name: "ChargeKitCore",
            path: "Sources/ChargeKitCore",
            swiftSettings: v5
        ),
        .executableTarget(
            name: "smcctl",
            dependencies: ["SMCKit"],
            path: "Sources/smcctl",
            swiftSettings: v5
        ),
        .executableTarget(
            name: "ChargeKitHelper",
            dependencies: ["SMCKit"],
            path: "Sources/ChargeKitHelper",
            swiftSettings: v5
        ),
        .executableTarget(
            name: "ChargeKitApp",
            dependencies: ["SMCKit", "ChargeKitCore"],
            path: "Sources/ChargeKitApp",
            swiftSettings: v5
        ),
        // Zero-dependency test runner: this SPM-only CLT has no usable
        // XCTest/swift-testing runtime, so acceptance tests run via
        // `swift run policy-tests`.
        .executableTarget(
            name: "policy-tests",
            dependencies: ["ChargeKitCore"],
            path: "Sources/PolicyTests",
            swiftSettings: v5
        ),
    ]
)
