// swift-tools-version:5.9
// FOUNTIS Connect for iOS. The library is a prebuilt XCFramework that Swift Package Manager downloads from this
// repository's release assets and checks against the checksum below.
//   .package(url: "https://github.com/darbaz/fountis-connect", from: "1.4.1")
import PackageDescription

let package = Package(
    name: "FountisConnect",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "FountisConnect", targets: ["FountisConnect"]),
    ],
    targets: [
        .binaryTarget(
            name: "FountisConnect",
            url: "https://github.com/darbaz/fountis-connect/releases/download/1.4.1/FountisConnect.xcframework.zip",
            checksum: "afec0c63df832862f2d83e093ea4ed6795c964f1ad8c92f4d821ce57f3180202"
        ),
    ]
)
