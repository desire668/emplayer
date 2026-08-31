// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EMPlayer",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "EMPlayerCore",
            targets: ["EMPlayerCore"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/kingslay/KSPlayer.git", from: "0.6.0"),
        .package(url: "https://github.com/evgenyneu/keychain-swift.git", from: "20.0.0"),
        .package(url: "https://github.com/onevcat/Kingfisher.git", from: "7.0.0"),
        .package(url: "https://github.com/SwiftyJSON/SwiftyJSON.git", from: "5.0.0")
    ],
    targets: [
        .target(
            name: "EMPlayerCore",
            dependencies: [
                .product(name: "KSPlayer", package: "KSPlayer"),
                .product(name: "KeychainSwift", package: "KeychainSwift"),
                .product(name: "Kingfisher", package: "Kingfisher"),
                .product(name: "SwiftyJSON", package: "SwiftyJSON")
            ],
            path: "Sources/EMPlayerCore"
        )
    ]
)
