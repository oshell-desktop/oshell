// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "SwiftTerm", platforms: [.macOS(.v15)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [.target(name: "SwiftTerm", exclude: ["iOS", "Mac/README.md", "Documentation.docc"],
                      resources: [.copy("Apple/Metal/Shaders.metal")])],
    swiftLanguageModes: [.v5]
)
