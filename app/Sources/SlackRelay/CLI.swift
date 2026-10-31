import Foundation

struct CLIResult: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: String

    var ok: Bool { status == 0 }
    var text: String { String(decoding: stdout, as: UTF8.self) }
    /// Last stderr line without the "slack-relay: " prefix, for inline errors.
    var message: String {
        let line = stderr.split(separator: "\n").last.map(String.init) ?? text.split(separator: "\n").last.map(String.init) ?? ""
        return line.replacingOccurrences(of: "slack-relay: ", with: "")
    }
}

protocol RelayCLI: Sendable {
    var location: String { get }
    func run(_ args: [String], stdin: String?) async -> CLIResult
}

extension RelayCLI {
    func run(_ args: String...) async -> CLIResult { await run(args, stdin: nil) }
}

/// Runs the real `slack-relay` with the user's login-shell PATH, so jq, bash 4 and the agent CLIs resolve
/// the same way they do in Terminal.
struct ShellCLI: RelayCLI {
    let executable: String
    let environment: [String: String]

    var location: String { executable }

    static let pathOverrideKey = "slackRelayPath"

    static func locate() -> ShellCLI {
        let path = loginPath()
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // A dev checkout's bin/slack-relay, three levels up from this file
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("bin/slack-relay").path
        let candidates = [UserDefaults.standard.string(forKey: pathOverrideKey)].compactMap { $0 }
            + path.split(separator: ":").map { "\($0)/slack-relay" }
            + ["\(home)/bin/slack-relay", "\(home)/.local/bin/slack-relay", checkout]
        let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "slack-relay"
        return ShellCLI(executable: found, environment: env)
    }

    /// PATH from an interactive login zsh; a Finder-launched app only gets /usr/bin:/bin.
    private static func loginPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallback = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let marker = "__SLACK_RELAY_PATH__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ilc", "printf '\(marker)%s\(marker)' \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return fallback.joined(separator: ":") }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate() }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let parts = out.components(separatedBy: marker)
        let shell = parts.count >= 3 ? parts[1].split(separator: ":").map(String.init) : []
        var seen = Set<String>()
        return (shell + fallback).filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    func run(_ args: [String], stdin: String?) async -> CLIResult {
        let executable = executable, environment = environment
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable.hasPrefix("/") ? executable : "/usr/bin/env")
            process.arguments = executable.hasPrefix("/") ? args : [executable] + args
            process.environment = environment
            let out = Pipe(), err = Pipe(), input = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = stdin == nil ? FileHandle.nullDevice : input
            do {
                try process.run()
            } catch {
                return CLIResult(status: 127, stdout: Data(), stderr: "can't run \(executable): \(error.localizedDescription)")
            }
            if let stdin {
                input.fileHandleForWriting.write(Data(stdin.utf8))
                try? input.fileHandleForWriting.close()
            }
            // Read both pipes before waiting so a large output can't fill the buffer and block
            async let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
            async let stderrData = err.fileHandleForReading.readDataToEndOfFile()
            let (o, e) = await (stdoutData, stderrData)
            process.waitUntilExit()
            return CLIResult(status: process.terminationStatus, stdout: o, stderr: String(decoding: e, as: UTF8.self))
        }.value
    }
}
