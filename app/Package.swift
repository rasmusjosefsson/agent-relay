// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SlackRelay",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SlackRelay", targets: ["SlackRelay"])
    ],
    targets: [
        // Native window over the slack-relay CLI; every read and write goes through its --json commands
        .executableTarget(
            name: "SlackRelay",
            path: "Sources/SlackRelay"
        )
    ]
)
