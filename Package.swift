// swift-tools-version:5.9
// FOUNTIS Connect for iOS. The library is a prebuilt XCFramework that Swift Package Manager downloads from this
// repository's release assets and checks against the checksum below.
//   .package(url: "https://github.com/darbaz/fountis-connect", from: "1.4.0")
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
            url: "https://github.com/darbaz/fountis-connect/releases/download/1.4.0/FountisConnect.xcframework.zip",
            checksum: "cfeb2a475a955dba871864c3783eade9c994e33064160bf298eefc7de4acc6b2"
        ),
    ]
)
