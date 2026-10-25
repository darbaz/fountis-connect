// swift-tools-version:5.9
// FOUNTIS Connect for iOS. The library is a prebuilt XCFramework that Swift Package Manager downloads from this
// repository's release assets and checks against the checksum below.
//   .package(url: "https://github.com/darbaz/fountis-connect", from: "1.2.0")
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
            url: "https://github.com/darbaz/fountis-connect/releases/download/1.2.0/FountisConnect.xcframework.zip",
            checksum: "1d70b430b891895a13eff2b4712b9318ceda438ee135fe7304df8208e7a62ddc"
        ),
    ]
)
