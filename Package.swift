// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CallTrans",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "calltrans",
            path: "Sources/CallTrans",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Speech"),
                .linkedFramework("Translation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        )
    ]
)
