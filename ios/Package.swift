// swift-tools-version:5.9
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
            resources: [
                .process("PrivacyInfo.xcprivacy"),
                // engine.html and the notification strings (i18n/*.json); refresh with scripts/sync-engine.sh
                .copy("Engine"),
            ]
        ),
        .testTarget(name: "FountisConnectTests", dependencies: ["FountisConnect"]),
    ]
)
