// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PanelCtl",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "panelctl", targets: ["panelctl"]),
        .executable(name: "PanelCtlApp", targets: ["PanelCtlApp"])
    ],
    targets: [
        .target(name: "PanelCtlCore"),
        .executableTarget(name: "panelctl", dependencies: ["PanelCtlCore"]),
        .executableTarget(name: "PanelCtlApp", dependencies: ["PanelCtlCore"]),
        .testTarget(name: "PanelCtlCoreTests", dependencies: ["PanelCtlCore"]),
        .testTarget(name: "PanelCtlAppTests", dependencies: ["PanelCtlApp", "PanelCtlCore"])
    ]
)
