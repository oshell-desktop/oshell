// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import PackageDescription
import Foundation
let testHarness = ProcessInfo.processInfo.environment["OSHELL_TEST_HARNESS"] == "1"
let appSettings: [SwiftSetting] = testHarness ? [.define("OSHELL_TEST_HARNESS")] : []
// Helpers expose CLI/IPC interfaces, never a dynamic-linking API. Hiding exports
// lets the release linker discard otherwise retained public Swift symbols.
let helperLinkerSettings: [LinkerSetting] = [.unsafeFlags(["-Xlinker", "-no_exported_symbols"], .when(configuration: .release))]
let package = Package(
    name: "OShell", platforms: [.macOS(.v15)],
    products: [.executable(name: "OShell", targets: ["OShell"]), .executable(name: "OShell-ZOC", targets: ["OShellZOC"]), .executable(name: "OShell-FileZilla", targets: ["OShellFileZilla"])],
    dependencies: [
        .package(path: "Vendor/SwiftTerm"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        // Keep transitive resolution compatible with the release toolchain (Swift 6.1).
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.6.4"),
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.2.1"),
    ],
    targets: [
        .binaryTarget(name: "Sparkle", path: "Vendor/Sparkle/Sparkle.xcframework"),
        .target(name: "OShellCore"),
        .executableTarget(name: "OShell-MCP", dependencies: ["OShellCore", .product(name: "MCP", package: "swift-sdk")], path: "Sources/OShellMCP", linkerSettings: helperLinkerSettings),
        .executableTarget(name: "OShell", dependencies: ["OShellCore", "Sparkle", .product(name: "SwiftTerm", package: "SwiftTerm")], exclude: testHarness ? [] : ["TestSupport"], swiftSettings: appSettings, linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "OShellProxy", dependencies: ["OShellCore"], linkerSettings: helperLinkerSettings),
        .executableTarget(name: "OShellAskpass", dependencies: ["OShellCore"], linkerSettings: helperLinkerSettings),
        .executableTarget(name: "OShellZOC", dependencies: ["OShellCore"], linkerSettings: helperLinkerSettings),
        .executableTarget(name: "OShellFileZilla", dependencies: ["OShellCore"], linkerSettings: helperLinkerSettings),
        .executableTarget(name: "OShellCoreChecks", dependencies: ["OShellCore"], path: "Tests/OShellCoreTests")
    ], swiftLanguageModes: [.v5]
)
