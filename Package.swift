// swift-tools-version:5.9
// Root manifest of the public FOUNTIS Connect repository, so that
//   .package(url: "https://github.com/darbaz/fountis-connect", from: "1.0.0")
// works. It mirrors ios/Package.swift (kept for the local sample app); the export script fails if the two drift apart.
import PackageDescription

let package = Package(
    name: "FountisConnect",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "FountisConnect", targets: ["FountisConnect"]),
    ],
    targets: [
        .target(
            name: "FountisConnect",
            path: "ios/Sources/FountisConnect",
            resources: [
                .process("PrivacyInfo.xcprivacy"),
                // engine.html and the notification strings (i18n/*.json)
                .copy("Engine"),
            ]
        ),
        .testTarget(
            name: "FountisConnectTests",
            dependencies: ["FountisConnect"],
            path: "ios/Tests/FountisConnectTests"
        ),
    ]
)
