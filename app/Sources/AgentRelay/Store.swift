import Foundation
import Observation

/// Everything the window shows, read through the CLI. Status polls; the rest loads when a pane opens.
@MainActor
@Observable
final class Store {
    let cli: RelayCLI

    var status: Status?
    var statusError: String?
    var connectors: [Connector]?
    var checking = Set<String>()
    var memory: Memory?
    var doctor: [DoctorCheck]?
    var doctorRunning = false
    var fields: ConfigFields?
    /// Per-key error from the last `config set`, shown under the field.
    var fieldErrors: [String: String] = [:]
    var serveAction: String?
    var serveError: String?
    var memoryError: String?
    /// Settings edited in the form but not saved yet, by key; Save writes them all at once.
    var drafts: [String: JSON] = [:]
    /// Keys whose text doesn't parse yet (JSON editor); Save waits for them.
    var invalid = Set<String>()
    var saving = false
    /// Counts Revert presses, so editors holding text that never became a draft reset too.
    var reverts = 0
    /// An error from the last save that names no field.
    var saveError: String?
    /// Last successful setting change, to tell whether serve has read it yet
    var savedAt: Date?
    /// `user` is read once when serve starts
    var restartNeeded = false
    /// Models each agent CLI lists, by runner, for the model fields' menus
    var models: [String: [String]] = [:]
    /// "#name" or "@handle" (DM) for each saved channel ID, nil when Slack won't tell
    var channelNames: [String: String?] = [:]
    /// Configured channels in order, with resolved names
    var channels: [ChannelName] = []
    /// Error from the last `remove`, by worker
    var workerErrors: [String: String] = [:]
    /// `agent-relay auth` in progress, and what it last said
    var slackSigningIn = false
    var slackAuthError: String?
    /// Set when several Slack workspaces are signed in; the pane asks which one.
    var slackWorkspaces: [SlackWorkspace]?

    private var polling: Task<Void, Never>?
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init(cli: RelayCLI) {
        self.cli = cli
    }

    var activeWorkers: [Worker] { status?.workers.filter(\.isActive) ?? [] }
    var waitingCount: Int { status?.workers.filter { $0.status == "waiting" }.count ?? 0 }
    var failingConnectors: Int { connectors?.filter { $0.ok == false }.count ?? 0 }
    var trigger: String { fields?.fields.first { $0.key == "trigger" }?.value?.string ?? "!" }

    /// Every dispatcher answer and worker, running ones first, then the newest finished.
    var runs: [Run] {
        guard let status else { return [] }
        let dispatcher = status.dispatcher
        let turns = (status.turns ?? []).map { Run(turn: $0, dispatcher: dispatcher) }
        let all = turns + status.workers.map(Run.init(worker:))
        return all.sorted { a, b in
            a.isActive != b.isActive ? a.isActive : (a.isActive ? a.started > b.started : (a.finished ?? a.started) > (b.finished ?? b.started))
        }
    }
    var runningCount: Int { runs.filter(\.isActive).count }

    /// Runs grouped by the Slack thread they belong to, running ones first, then the newest.
    var conversations: [Conversation] {
        var groups: [String: [Run]] = [:]
        var order: [String] = []
        for run in runs {
            let key = run.threadKey ?? run.id
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(run)
        }
        return order.map { key in
            Conversation(id: key, runs: groups[key]!.sorted { $0.started < $1.started })
        }.sorted { a, b in
            a.isActive != b.isActive ? a.isActive : a.latest > b.latest
        }
    }
    /// Error from the last Stop, by run
    var runErrors: [String: String] = [:]
    /// Run IDs a Stop was pressed for and that still show as running
    var stopping = Set<String>()

    enum Applied { case live, pending, restart }

    /// Whether the running serve uses the saved settings; nil when it isn't running.
    var applied: Applied? {
        guard let serve = status?.serve, serve.running else { return nil }
        if restartNeeded { return .restart }
        // a starting serve writes serve.json just before it reads the config; one from before live reload never writes config_loaded
        guard let loaded = serve.configLoaded.flatMap({ ISO8601DateFormatter().date(from: $0) }) else {
            return serve.lastPoll == nil ? .pending : .restart
        }
        // config_loaded has whole seconds
        if let savedAt, loaded < savedAt.addingTimeInterval(-1) { return .pending }
        return .live
    }

    func startPolling() {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ result: CLIResult) -> T? {
        try? decoder.decode(type, from: result.stdout)
    }

    func refreshStatus() async {
        let result = await cli.run("status", "--json")
        if let status = decode(Status.self, result) {
            if status != self.status { self.status = status }
            statusError = nil
        } else {
            statusError = result.message.isEmpty ? "agent-relay status failed" : result.message
        }
    }

    /// `connectors --json` exits 1 when any check fails; the JSON is still complete.
    func checkConnectors(_ names: [String] = []) async {
        let all = names.isEmpty ? (connectors?.map(\.name) ?? []) : names
        checking.formUnion(all.isEmpty ? ["*"] : all)
        defer { checking.subtract(all.isEmpty ? ["*"] : all) }
        guard let rows = decode([Connector].self, await cli.run(["connectors", "--json"] + names, stdin: nil)) else { return }
        if names.isEmpty || connectors == nil {
            connectors = rows
        } else {
            for row in rows {
                if let i = connectors?.firstIndex(where: { $0.name == row.name }) { connectors?[i] = row }
            }
        }
    }

    /// Restarts Slack once, reads its local session, and stores the token and d cookie.
    /// With several signed-in teams, leaves the choice in `slackWorkspaces`.
    func signInToSlack(workspace: String? = nil) async {
        slackSigningIn = true
        defer { slackSigningIn = false }
        slackAuthError = nil
        var args = ["auth", "--json"]
        if let workspace, !workspace.isEmpty { args += ["--workspace", workspace] }
        let result = await cli.run(args, stdin: nil)
        if result.ok {
            slackWorkspaces = nil
            await checkConnectors(["slack"])
            await loadFields()
            await refreshStatus()
            return
        }
        if let failure = try? decoder.decode(SlackAuthFailure.self, from: result.stdout),
           failure.error == "multiple_workspaces",
           let workspaces = failure.workspaces, !workspaces.isEmpty {
            slackWorkspaces = workspaces
            return
        }
        slackAuthError = result.message
    }

    func loadMemory(channel: String? = nil) async {
        var args = ["memory", "--json"]
        if let channel, !channel.isEmpty { args += ["--channel", channel] }
        memory = decode(Memory.self, await cli.run(args, stdin: nil))
    }

    func saveMemory(_ text: String, channel: String? = nil) async {
        var args = ["memory", "set"]
        if let channel, !channel.isEmpty { args += ["--channel", channel] }
        let result = await cli.run(args, stdin: text)
        memoryError = result.ok ? nil : result.message
        await loadMemory(channel: channel)
    }

    func channelConfig(for channelID: String) -> ChannelConfig {
        guard case .object(let map)? = value("channel_config"),
              case .object(let raw)? = map[channelID] else { return ChannelConfig() }
        let policy = raw["memory_policy"]?.string ?? "explicit"
        var skills: [String] = []
        if case .array(let items)? = raw["skills"] { skills = items.compactMap(\.string) }
        let repo = raw["repo"]?.string ?? ""
        let instructions = raw["instructions"]?.string ?? ""
        return ChannelConfig(memoryPolicy: policy, skills: skills, repo: repo, instructions: instructions)
    }

    var repoNames: [String] {
        guard case .object(let map)? = value("repos") else { return [] }
        return map.keys.sorted()
    }

    @discardableResult
    func saveChannelConfig(_ channelID: String, _ config: ChannelConfig) async -> Bool {
        let key = "channel_config.\(channelID)"
        if config.isDefault {
            await unset(key)
            return fieldErrors[key] == nil
        }
        var dict: [String: Any] = ["memory_policy": config.memoryPolicy]
        if !config.skills.isEmpty { dict["skills"] = config.skills }
        if !config.repo.isEmpty { dict["repo"] = config.repo }
        if !config.instructions.isEmpty { dict["instructions"] = config.instructions }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else { return false }
        return await set(key, json: String(decoding: data, as: UTF8.self))
    }

    func runDoctor() async {
        doctorRunning = true
        defer { doctorRunning = false }
        // doctor exits 1 when a check fails
        doctor = decode([DoctorCheck].self, await cli.run("doctor", "--json"))
    }

    /// The value the form shows: the draft when there is one.
    func value(_ key: String) -> JSON? {
        drafts[key] ?? fields?.fields.first { $0.key == key }?.value
    }

    /// Records an edit; one that goes back to the saved value is no edit.
    func edit(_ key: String, _ value: JSON) {
        let saved = fields?.fields.first { $0.key == key }?.value
        drafts[key] = value == saved ? nil : value
        fieldErrors[key] = nil
        saveError = nil
    }

    func revert() {
        drafts = [:]
        invalid = []
        reverts += 1
        fieldErrors = [:]
        saveError = nil
    }

    /// Writes every draft with one `config apply`, so settings that depend on each other change together.
    func save() async {
        guard !drafts.isEmpty, invalid.isEmpty else { return }
        saving = true
        defer { saving = false }
        let patch = ["set": drafts.mapValues(\.any)]
        let data = (try? JSONSerialization.data(withJSONObject: patch)) ?? Data("{}".utf8)
        let result = await cli.run(["config", "apply"], stdin: String(decoding: data, as: UTF8.self))
        fieldErrors = [:]
        guard result.ok else {
            // "dispatcher.icon, worker.icon: message" goes under each key it names
            var unplaced: [String] = []
            for line in result.text.split(separator: "\n").map(String.init) + (result.text.isEmpty ? [result.message] : []) {
                guard let colon = line.range(of: ": ") else { unplaced.append(line); continue }
                let keys = line[..<colon.lowerBound].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let message = String(line[colon.upperBound...])
                let shown = keys.filter { key in fields?.fields.contains { $0.key == key } == true }
                if shown.isEmpty { unplaced.append(line) }
                for key in shown { fieldErrors[key] = fieldErrors[key].map { "\($0) \(message)" } ?? message }
            }
            saveError = unplaced.isEmpty ? nil : unplaced.joined(separator: "\n")
            return
        }
        for key in drafts.keys { saved(key) }
        drafts = [:]
        saveError = nil
        await loadFields()
        await refreshStatus()
    }

    func loadFields() async {
        async let names = cli.run("channels", "--json")
        if models.isEmpty, let listed = decode([String: [String]].self, await cli.run("models", "--json")) { models = listed }
        fields = decode(ConfigFields.self, await cli.run("config", "fields", "--json"))
        if let rows = decode([ChannelName].self, await names) {
            channels = rows
            channelNames = Dictionary(rows.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Writes one setting as JSON so strings, numbers and objects all round-trip; returns success.
    @discardableResult
    func set(_ key: String, json: String) async -> Bool {
        let result = await cli.run("config", "set", key, json)
        fieldErrors[key] = result.ok ? nil : result.message
        if result.ok {
            saved(key)
            await loadFields()
            await refreshStatus()
        }
        return result.ok
    }

    func set(_ key: String, string: String) async -> Bool {
        let data = try? JSONSerialization.data(withJSONObject: string, options: .fragmentsAllowed)
        return await set(key, json: data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\"")
    }

    func unset(_ key: String) async {
        let result = await cli.run("config", "unset", key)
        fieldErrors[key] = result.ok ? nil : result.message
        if result.ok { saved(key) }
        await loadFields()
    }

    private func saved(_ key: String) {
        savedAt = .now
        if key == "user", status?.serve.running == true { restartNeeded = true }
    }

    /// Stops the worker if it runs and deletes its record and log.
    func removeWorker(_ name: String) async {
        let result = await cli.run("remove", name)
        workerErrors[name] = result.ok ? nil : result.message
        await refreshStatus()
    }

    /// Stops one dispatcher answer or worker, the way "!<name> stop" does in Slack.
    func cancel(_ run: Run) async {
        stopping.insert(run.id)
        defer { stopping.remove(run.id) }
        let result = await cli.run("cancel", run.id)
        runErrors[run.id] = result.ok ? nil : result.message
        await refreshStatus()
    }

    /// The steps a run's agent took so far, oldest first; nil when the CLI can't say.
    func activity(_ id: String) async -> [ActivityRow]? {
        decode([ActivityRow].self, await cli.run("activity", id, "--json", "--limit", "500"))
    }

    func startServe() async { await serve("start") }
    func stopServe() async { await serve("stop") }

    func restartServe() async {
        await serve("stop")
        if serveError == nil { await serve("start") }
    }

    private func serve(_ verb: String) async {
        serveAction = verb
        defer { serveAction = nil }
        let result = await cli.run(verb)
        serveError = result.ok ? nil : result.message
        if result.ok && verb == "start" { restartNeeded = false }
        await refreshStatus()
    }
}
