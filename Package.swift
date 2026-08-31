// swift-tools-version:5.9
import PackageDescription

// EMPlayerCore: 纯业务/网络/模型层的本地 Swift Package。
// 由 XcodeGen 在 project.yml 里以 packages.EMPlayerCore.path: "." 引入，
// iOS App target (EMPlayer) 通过 - package: EMPlayerCore 链接本 package 输出的库。
let package = Package(
    name: "EMPlayerCore",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        // 主产物：EMPlayerCore library（project.yml 里 package: EMPlayerCore 找的就是这个）
        .library(name: "EMPlayerCore", targets: ["EMPlayerCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/kingslay/KSPlayer.git", branch: "main"),
        .package(url: "https://github.com/evgenyneu/keychain-swift.git", from: "20.0.0"),
        .package(url: "https://github.com/onevcat/Kingfisher.git", from: "7.0.0"),
        .package(url: "https://github.com/SwiftyJSON/SwiftyJSON.git", from: "5.0.0")
    ],
    targets: [
        .target(
            name: "EMPlayerCore",
            dependencies: [
                .product(name: "KSPlayer",          package: "KSPlayer"),
                .product(name: "KeychainSwift",     package: "keychain-swift"),
                .product(name: "Kingfisher",        package: "Kingfisher"),
                .product(name: "SwiftyJSON",        package: "SwiftyJSON")
            ],
            path: "Sources/EMPlayerCore"
        )
    ]
)
