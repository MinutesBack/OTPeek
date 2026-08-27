// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OTPeek",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OTPeek",
            path: "Sources/OTPeek",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
                .linkedFramework("Network"),
                .linkedFramework("AuthenticationServices"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
