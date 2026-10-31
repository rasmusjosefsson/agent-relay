import Foundation

/// `slack-relay status --json`
struct Status: Decodable, Equatable {
    var serve: Serve
    var dispatcher: Dispatcher
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
    var thread: String?
    var turns: Int?
    var task: String?
    var started: String?
    var finished: String?
    var status: String
    var pid: Int?
    var log: String?

    var id: String { name }
    var isActive: Bool { status == "running" || status == "waiting" }
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
