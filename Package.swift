// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CairnInstruments",
    platforms: [.macOS(.v13)],
    products: [.library(name: "CairnInstruments", targets: ["CairnInstruments"])],
    targets: [
        .target(name: "CairnInstruments"),
        .testTarget(name: "CairnInstrumentsTests", dependencies: ["CairnInstruments"]),
    ]
)
