import Foundation

/// `slack-relay status --json`
struct Status: Decodable, Equatable {
    var serve: Serve
    var dispatcher: Dispatcher
    /// Dispatcher answers, newest first; absent from a CLI older than the app
    var turns: [Turn]?
    var workers: [Worker]
    var paths: Paths

    struct Serve: Decodable, Equatable {
        var pid: Int?
        var channel: String?
        var channels: [String]?
        var dispatcher: String?
        var trigger: String?
        /// When serve last read the config; it rereads it on the poll after any change
        var configLoaded: String?
        var started: String?
        var lastPoll: String?
        var running: Bool
        var busy: Busy?
        /// The workspace address, like https://acme.slack.com/, for links to messages
        var slackUrl: String?
    }

    struct Busy: Decodable, Equatable {
        var label: String
        var text: String
        var since: String
    }

    struct Dispatcher: Decodable, Equatable {
        var label: String
        var runner: String
        var model: String
        var workdir: String
        var memory: String
    }

    struct Paths: Decodable, Equatable {
        var config: String
        var state: String
        var serveLog: String
    }
}

struct Worker: Decodable, Equatable, Identifiable {
    var name: String
    var repo: String?
    var dir: String?
    var runner: String
    var model: String?
    var session: String?
    var channel: String?
    var thread: String?
    var turns: Int?
    var task: String?
    var started: String?
    /// When the current or last turn started
    var turnStarted: String?
    var finished: String?
    var status: String
    var pid: Int?
    var log: String?
    /// The agent's newest step while it works
    var last: ActivityRow?

    var id: String { name }
    var isActive: Bool { status == "running" || status == "waiting" }
}

/// One dispatcher answer from `status --json` `turns`: running, or one of the newest finished.
struct Turn: Decodable, Equatable, Identifiable {
    var id: String
    var label: String?
    var text: String
    var since: String
    var finished: String?
    var status: String
    var runner: String?
    var model: String?
    var answer: String?
    var last: ActivityRow?
    var channel: String?
    /// "-" when the answer went to the channel
    var thread: String?
    /// The Slack message that asked
    var ts: String?
    var dir: String?
    /// Earlier messages in its thread, oldest first, as the dispatcher saw them
    var context: [ContextLine]?

    var isActive: Bool { status == "running" }
}

/// One earlier message in a thread: from you (agent posts included), a bot, or someone else.
struct ContextLine: Decodable, Equatable, Hashable {
    var from: String
    var text: String
}

/// One step from `slack-relay activity --json`.
struct ActivityRow: Decodable, Equatable, Hashable {
    /// relay, start, thinking, tool, output, text, error, or done
    var kind: String
    var text: String
    /// All of it: the prompt, a tool's input or output, a long reply
    var detail: String?
}

/// The runs from one Slack thread, oldest first, or a single run asked outside a thread.
struct Conversation: Identifiable, Equatable {
    var id: String
    var runs: [Run]

    var isActive: Bool { runs.contains(where: \.isActive) }
    var latest: String { runs.map { $0.finished ?? $0.started }.max() ?? "" }
    var isThread: Bool { runs.count > 1 }

    /// The whole thread in Slack: its first run's link without a message
    func slackLink(base: String?) -> URL? {
        guard var first = runs.first else { return nil }
        first.ts = nil
        return first.slackLink(base: base)
    }
}

/// A dispatcher answer or a worker, as the Activity pane lists them.
struct Run: Identifiable, Equatable {
    enum Kind { case answer, worker }

    /// Turn ID or worker name; what `activity` and `cancel` take
    var id: String
    var kind: Kind
    var label: String
    var status: String
    /// The Slack message, or the worker's task
    var text: String
    var started: String
    var finished: String?
    var agent: String
    var repo: String?
    var last: ActivityRow?
    var answer: String?
    var channel: String?
    var thread: String?
    var ts: String?
    var dir: String?
    /// Earlier messages in its Slack thread; empty for workers and channel messages
    var context: [ContextLine] = []

    var isActive: Bool { status == "running" || status == "waiting" }

    /// "<channel>/<thread>" when it was asked in a Slack thread, so runs in one thread group together
    var threadKey: String? {
        guard let thread, thread != "-", !thread.isEmpty else { return nil }
        return "\(channel ?? "")/\(thread)"
    }

    /// The Slack message this came from, or its thread; nil without the workspace address.
    func slackLink(base: String?) -> URL? {
        guard var base, let channel, !channel.isEmpty else { return nil }
        if !base.hasSuffix("/") { base += "/" }
        let inThread = thread.map { $0 != "-" && !$0.isEmpty } ?? false
        guard let message = ts ?? (inThread ? thread : nil) else { return URL(string: "\(base)archives/\(channel)") }
        var link = "\(base)archives/\(channel)/p\(message.replacingOccurrences(of: ".", with: ""))"
        if inThread, let thread { link += "?thread_ts=\(thread)&cid=\(channel)" }
        return URL(string: link)
    }

    init(turn: Turn, dispatcher: Status.Dispatcher) {
        id = turn.id
        kind = .answer
        label = turn.label ?? dispatcher.label
        status = turn.status
        text = turn.text
        started = turn.since
        finished = turn.finished
        agent = Self.agent(turn.runner ?? dispatcher.runner, turn.model)
        last = turn.last
        answer = turn.answer
        channel = turn.channel
        thread = turn.thread
        ts = turn.ts
        dir = turn.dir
        context = turn.context ?? []
    }

    init(worker: Worker) {
        id = worker.name
        kind = .worker
        label = worker.name
        status = worker.status
        text = worker.task ?? ""
        started = worker.turnStarted ?? worker.started ?? ""
        finished = worker.finished
        agent = Self.agent(worker.runner, worker.model)
        repo = worker.repo
        last = worker.last
        channel = worker.channel
        thread = worker.thread
        dir = worker.dir
    }

    private static func agent(_ runner: String, _ model: String?) -> String {
        [runner, model.flatMap { $0.isEmpty ? nil : $0 }].compactMap { $0 }.joined(separator: " · ")
    }
}

/// `slack-relay connectors --json`; `ok` is nil when the connector is turned off.
struct Connector: Decodable, Equatable, Identifiable {
    var name: String
    var title: String
    var check: String
    /// Slack: checked by slack-relay itself, so there's no command to edit
    var builtin: Bool?
    var ok: Bool?
    var detail: String

    var id: String { name }
}

/// `slack-relay memory --json`
struct Memory: Decodable, Equatable {
    var path: String
    var exists: Bool
    var lines: Int
    var limit: Int
    var text: String
}

/// `slack-relay doctor --json`
struct DoctorCheck: Decodable, Equatable, Identifiable {
    var check: String
    var ok: Bool
    var detail: String

    var id: String { check }
}

/// `slack-relay channels --json`
struct ChannelName: Decodable, Equatable {
    var id: String
    var name: String?

    /// "#general", or "@handle" for a DM
    var label: String? { name.map { $0.hasPrefix("@") ? $0 : "#\($0)" } }
}

/// `slack-relay config fields --json`
struct ConfigFields: Decodable, Equatable {
    var groups: [Group]
    var fields: [Field]

    struct Group: Decodable, Equatable, Identifiable {
        var key: String
        var title: String
        var description: String
        var id: String { key }
    }

    struct Field: Decodable, Equatable, Identifiable {
        var key: String
        var group: String
        var title: String
        var description: String
        var type: String
        var `enum`: [String]?
        var value: JSON?
        var id: String { key }
    }
}

/// Any JSON value, kept so a setting can be shown and written back unchanged.
enum JSON: Decodable, Equatable {
    case string(String), number(Double), bool(Bool), array([JSON]), object([String: JSON]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    var any: Any {
        switch self {
        case .string(let s): s
        case .number(let n): n == n.rounded() ? Int(n) as Any : n
        case .bool(let b): b
        case .array(let a): a.map(\.any)
        case .object(let o): o.mapValues(\.any)
        case .null: NSNull()
        }
    }

    var string: String? { if case .string(let s) = self { s } else { nil } }

    /// Compact JSON text, keys sorted; `pretty` for the editors.
    func text(pretty: Bool = false) -> String {
        if case .string(let s) = self { return s }
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        guard let data = try? JSONSerialization.data(withJSONObject: any, options: options) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension String {
    /// "2026-10-30T22:19:58Z" → "5 min ago"
    var relativeTime: String {
        guard let date = ISO8601DateFormatter().date(from: self) else { return self }
        if abs(date.timeIntervalSinceNow) < 5 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: .now)
    }

    var abbreviatingHome: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return hasPrefix(home) ? "~" + dropFirst(home.count) : self
    }
}
