// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import PackageDescription
import Foundation
let testHarness = ProcessInfo.processInfo.environment["OSHELL_TEST_HARNESS"] == "1"
let appSettings: [SwiftSetting] = testHarness ? [.define("OSHELL_TEST_HARNESS")] : []
let package = Package(
    name: "OShell", platforms: [.macOS(.v15)],
    products: [.executable(name: "OShell", targets: ["OShell"]), .executable(name: "OShell-ZOC", targets: ["OShellZOC"]), .executable(name: "OShell-FileZilla", targets: ["OShellFileZilla"])],
    dependencies: [.package(path: "Vendor/SwiftTerm"), .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")],
    targets: [
        .binaryTarget(name: "Sparkle", path: "Vendor/Sparkle/Sparkle.xcframework"),
        .target(name: "OShellCore"),
        .executableTarget(name: "OShell-MCP", dependencies: ["OShellCore", .product(name: "MCP", package: "swift-sdk")], path: "Sources/OShellMCP"),
        .executableTarget(name: "OShell", dependencies: ["OShellCore", "Sparkle", .product(name: "SwiftTerm", package: "SwiftTerm")], exclude: testHarness ? [] : ["TestSupport"], swiftSettings: appSettings, linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "OShellProxy", dependencies: ["OShellCore"]),
        .executableTarget(name: "OShellAskpass", dependencies: ["OShellCore"]),
        .executableTarget(name: "OShellZOC", dependencies: ["OShellCore"]),
        .executableTarget(name: "OShellFileZilla", dependencies: ["OShellCore"]),
        .executableTarget(name: "OShellCoreChecks", dependencies: ["OShellCore"], path: "Tests/OShellCoreTests")
    ], swiftLanguageModes: [.v5]
)
