// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AgentRelay",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AgentRelay", targets: ["AgentRelay"])
    ],
    targets: [
        // Native window over the agent-relay CLI; every read and write goes through its --json commands
        .executableTarget(
            name: "AgentRelay",
            path: "Sources/AgentRelay"
        )
    ]
)
