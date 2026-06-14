// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "beauty_sdk",
    platforms: [
        .iOS("14.0")
    ],
    products: [
        .library(name: "beauty-sdk", targets: ["beauty_sdk"])
    ],
    dependencies: [
        // Flutter 工具链在 build 时自动注入（路径相对插件 ios/beauty_sdk 目录）
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        // 原生美颜引擎（方案 A：二进制分发，不暴露源码）。
        // 引擎仓库的 Package.swift 用 binaryTarget 指向 GitHub Release 里的
        // BeautySDK.xcframework.zip（见 clients/ios/BeautySDK/Package-binary.swift.template）。
        .package(
            url: "https://github.com/OrangeCloud-SDK/orangecloud-beauty-ios.git",
            from: "1.0.1"
        )
    ],
    targets: [
        .target(
            name: "beauty_sdk",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "BeautySDK", package: "orangecloud-beauty-ios")
            ]
        )
    ]
)
