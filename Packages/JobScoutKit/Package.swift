// swift-tools-version: 6.0
//
//  Package.swift
//  JobScout
//
//  Created by Andrii Bryzhnychenko on 10/29/26.
//

import PackageDescription

let package = Package(
    name: "JobScoutKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "JobScoutKit", targets: ["JobScoutKit"])],
    targets: [
        .target(name: "JobScoutKit"),
        .testTarget(name: "JobScoutKitTests", dependencies: ["JobScoutKit"])
    ]
)
