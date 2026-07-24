// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PanelCtl",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "panelctl", targets: ["panelctl"])
    ],
    targets: [
        .target(name: "PanelCtlCore"),
        .executableTarget(name: "panelctl", dependencies: ["PanelCtlCore"]),
        .testTarget(name: "PanelCtlCoreTests", dependencies: ["PanelCtlCore"])
    ]
)
