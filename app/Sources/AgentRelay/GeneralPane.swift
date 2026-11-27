import AppKit
import SwiftUI

/// The relay and the settings that matter day to day; everything else from the schema sits under Advanced.
struct GeneralPane: View {
    let store: Store
    @State private var advanced = false

    /// Shown above Advanced, in this order, with a title fit for the mixed sections.
    private static let slackKeys: [(String, String?)] = [
        ("trigger", nil),
        ("dispatcher.icon", "Dispatcher icon"), ("worker.icon", "Worker icon"), ("show_label", nil),
        ("reply_in_thread", nil), ("thinking", nil),
    ]

    private func field(_ key: String) -> ConfigFields.Field? { store.fields?.fields.first { $0.key == key } }

    /// dispatcher.runner and the model for that runner only.
    private func agentKeys(_ role: String, name: String) -> [(String, String?)] {
        let runner = store.value("\(role).runner")?.string ?? "opencode"
        return [("\(role).runner", "\(name) agent CLI"), ("\(role).models.\(runner)", "\(name) model")]
    }

    private var agentRows: [(String, String?)] {
        [("dispatcher.label", "Dispatcher name")] + agentKeys("dispatcher", name: "Dispatcher") + agentKeys("worker", name: "Worker")
    }

    var body: some View {
        Form {
            PaneHeader(item: .general)
            if let error = store.statusError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    LabeledContent("agent-relay", value: store.cli.location.abbreviatingHome)
                }
            }
            if let status = store.status { RelaySection(status: status, store: store) }
            if let fields = store.fields {
                rows("Slack", Self.slackKeys, channels: true)
                rows("Agents", agentRows)
                rows("Repos", [("repos", nil)])
                let shown = Set((Self.slackKeys + agentRows + [("repos", nil)]).map(\.0) + ["channel", "channels", "channel_config"])
                // other runners' models stay editable here
                let rest = fields.fields.filter { !shown.contains($0.key) }
                Section {
                    DisclosureGroup("Advanced", isExpanded: $advanced) {
                        ForEach(rest) { FieldRow(field: $0, store: store) }
                    }
                } footer: {
                    if let config = store.status?.paths.config {
                        HStack(spacing: 4) {
                            Text("Saved in")
                            Button(config.abbreviatingHome) { reveal(config) }.buttonStyle(.link)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .safeAreaInset(edge: .bottom, spacing: 0) { SaveBar(store: store) }
        .task { await store.loadFields() }
    }

    @ViewBuilder
    private func rows(_ header: String, _ keys: [(String, String?)], channels: Bool = false) -> some View {
        Section(header) {
            if channels { ChannelsRow(store: store) }
            ForEach(keys, id: \.0) { key, title in
                if let field = field(key) { FieldRow(field: field, store: store, label: title) }
            }
        }
    }
}


/// channel and channels as one list: the first is `channel`, the rest `channels`.
private struct ChannelsRow: View {
    let store: Store
    @State private var draft = ""

    private var current: [String] {
        let main = store.value("channel")?.string ?? ""
        var extra: [String] = []
        if case .array(let items)? = store.value("channels") { extra = items.compactMap(\.string) }
        return ([main] + extra).reduce(into: []) { list, id in if !id.isEmpty && !list.contains(id) { list.append(id) } }
    }

    /// "#general, C0123 (name unknown)"; Slack is only asked about saved channels
    private var names: String {
        current.map { id in
            switch store.channelNames[id] {
            case .some(.some(let name)): name
            case .some(.none): "\(id) (name unknown)"
            case .none: "\(id) (save to see its name)"
            }
        }.joined(separator: ", ")
    }

    private var error: String? {
        if Self.ids(draft).isEmpty { return "Add at least one channel." }
        return store.fieldErrors["channel"] ?? store.fieldErrors["channels"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                VStack(alignment: .trailing, spacing: 4) {
                    TextField("", text: $draft, prompt: Text("C0123456789, …"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                        .onChange(of: draft) { _, text in edit(text) }
                    if !names.isEmpty {
                        Text(names).font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing).frame(width: 240, alignment: .trailing)
                    }
                }
            } label: {
                TitleLabel(title: "Channels", description: "IDs or channel links, comma separated. The relay reads and posts only in these, and agents answer in the one you wrote in.",
                           edited: store.drafts["channel"] != nil || store.drafts["channels"] != nil)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
            }
        }
        .onChange(of: current, initial: true) { _, ids in if Self.ids(draft) != ids { draft = ids.joined(separator: ", ") } }
    }

    /// ".../archives/C0123456789" → "C0123456789"
    private static func id(_ text: String) -> String {
        if let match = text.firstMatch(of: #/archives\/([A-Z0-9]+)/#) { return String(match.1) }
        return text.hasPrefix("id:") ? String(text.dropFirst(3)) : text
    }

    private static func ids(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { id(String($0)) }
            .reduce(into: [String]()) { list, id in if !list.contains(id) { list.append(id) } }
    }

    private func edit(_ text: String) {
        let ids = Self.ids(text)
        guard let first = ids.first, ids != current else { return }
        store.edit("channel", .string(first))
        store.edit("channels", .array(ids.dropFirst().map { .string($0) }))
    }
}

/// Start/stop, and what serve is doing right now.
private struct RelaySection: View {
    let status: Status
    let store: Store

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Circle()
                    .fill(status.serve.running ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 10, height: 10)
                TitleLabel(
                    title: status.serve.running ? "Listening in Slack" : "Not running",
                    description: status.serve.running
                        ? "Checked Slack \(status.serve.lastPoll?.relativeTime ?? "–") · started \(status.serve.started?.relativeTime ?? "–")"
                        : "Start it to answer \(store.trigger) messages in your channels."
                )
                Spacer()
                if let action = store.serveAction {
                    ProgressView().controlSize(.small)
                    Text(action == "start" ? "Starting…" : "Stopping…").foregroundStyle(.secondary)
                } else if status.serve.running {
                    if store.applied == .restart {
                        Button("Restart") { Task { await store.restartServe() } }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Restart") { Task { await store.restartServe() } }
                    }
                    Button("Stop") { Task { await store.stopServe() } }
                } else {
                    Button("Start") { Task { await store.startServe() } }
                        .buttonStyle(.borderedProminent)
                }
            }
            if let error = store.serveError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            if let busy = status.serve.busy {
                LabeledContent {
                    Text(busy.text).lineLimit(2).foregroundStyle(.secondary)
                } label: {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("\(busy.label) since \(busy.since.relativeTime)")
                    }
                }
            }
            LabeledContent("Log") {
                Button(status.paths.serveLog.abbreviatingHome) { openFile(status.paths.serveLog) }
                    .buttonStyle(.link)
            }
        } header: {
            Text("Relay")
        } footer: {
            if store.applied == .live {
                Label("Answers \(status.serve.trigger ?? store.trigger)\(status.serve.dispatcher ?? "") and worker names, nothing else.",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Pinned under the form: unsaved changes with Revert and Save, then whether the relay uses what was saved.
private struct SaveBar: View {
    let store: Store

    /// How long "Saved" stays up once the relay uses it
    private static let linger: TimeInterval = 20

    private var recentlySaved: Bool { store.savedAt.map { Date.now.timeIntervalSince($0) < Self.linger } ?? false }

    var body: some View {
        if !store.drafts.isEmpty || !store.invalid.isEmpty {
            bar {
                Image(systemName: "pencil.circle.fill").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    let count = store.drafts.count + store.invalid.subtracting(store.drafts.keys).count
                    Text(count == 1 ? "1 unsaved change" : "\(count) unsaved changes").fontWeight(.medium)
                    if let error = store.saveError {
                        Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
                    } else if !store.fieldErrors.isEmpty {
                        Text("Not saved. Fix the settings marked in red.").font(.caption).foregroundStyle(.red)
                    } else if !store.invalid.isEmpty {
                        Text("Fix the JSON before saving.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if store.saving { ProgressView().controlSize(.small) }
                Button("Revert") { store.revert() }
                    .disabled(store.saving)
                Button("Save") { Task { await store.save() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(store.saving || store.drafts.isEmpty || !store.invalid.isEmpty)
            }
        } else if store.applied == .restart && (store.restartNeeded || store.savedAt != nil) {
            bar {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(store.restartNeeded
                     ? "Saved. The Slack user changes when the relay restarts."
                     : "Saved. The relay still runs with the settings it started with.")
                Spacer()
                Button("Restart Relay") { Task { await store.restartServe() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.serveAction != nil)
            }
        } else if recentlySaved {
            bar {
                switch store.applied {
                case .pending?:
                    ProgressView().controlSize(.small)
                    Text("Saved. The relay picks it up in a few seconds…")
                case .live?:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Saved. The relay is using it.")
                default:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Saved. It applies when you start the relay.")
                }
                Spacer()
            }
        }
    }

    private func bar(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10, content: content)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .background(.bar)
    }
}

struct FieldRow: View {
    let field: ConfigFields.Field
    let store: Store
    var label: String?

    private var title: String {
        if let label { return label }
        let parts = field.key.split(separator: ".")
        // dispatcher.models.claude → "Model for claude"
        return parts.count == 3 && parts[1] == "models" ? "Model for \(field.title)" : field.title
    }

    private var error: String? { store.fieldErrors[field.key] }
    /// dispatcher.models.claude → what `claude` lists
    private var suggestions: [String] {
        let parts = field.key.split(separator: ".")
        return parts.count == 3 && parts[1] == "models" ? store.models[String(parts[2])] ?? [] : []
    }
    private var edited: Bool { store.drafts[field.key] != nil || store.invalid.contains(field.key) }
    private var titleLabel: TitleLabel { TitleLabel(title: title, description: field.description, edited: edited) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch field.type {
            case "boolean":
                Toggle(isOn: Binding(
                    get: { store.value(field.key) == .bool(true) },
                    set: { store.edit(field.key, .bool($0)) }
                )) { titleLabel }
            case "string" where field.enum != nil:
                Picker(selection: Binding(
                    get: { store.value(field.key)?.string ?? "" },
                    set: { store.edit(field.key, .string($0)) }
                )) {
                    ForEach(field.enum ?? [], id: \.self) { Text($0).tag($0) }
                } label: { titleLabel }
            case "map":
                MapEditor(field: field, label: titleLabel, store: store)
            case "json":
                JSONEditor(field: field, label: titleLabel, store: store)
            default:
                TextRow(field: field, label: titleLabel, store: store, suggestions: suggestions)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

/// String, integer and list settings, edited as text.
private struct TextRow: View {
    let field: ConfigFields.Field
    let label: TitleLabel
    let store: Store
    var suggestions: [String] = []
    @State private var draft = ""

    private static func text(_ value: JSON?) -> String {
        switch value {
        case .array(let items)?: items.map { $0.text() }.joined(separator: ", ")
        case let value?: value.text()
        case nil: ""
        }
    }

    private func parse(_ text: String) -> JSON {
        switch field.type {
        case "integer":
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return Int(trimmed).map { .number(Double($0)) } ?? .string(trimmed)
        case "array":
            return .array(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { .string($0) })
        default:
            return .string(text)
        }
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 4) {
                TextField("", text: $draft, prompt: Text(field.type == "array" ? "comma separated" : "default"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onChange(of: draft) { _, text in store.edit(field.key, parse(text)) }
                if !suggestions.isEmpty { SuggestionMenu(items: suggestions, draft: $draft) }
            }
        } label: {
            label
        }
        // after Revert or Save; not while typing, so "a, " keeps its comma
        .onChange(of: store.value(field.key), initial: true) { _, value in
            if parse(draft) != value { draft = Self.text(value) }
        }
    }
}

/// Pick from what the agent CLI lists, grouped by provider ("github-copilot/claude-…"); typing still works.
private struct SuggestionMenu: View {
    let items: [String]
    @Binding var draft: String

    private var groups: [(String, [String])] {
        Dictionary(grouping: items) { $0.split(separator: "/", maxSplits: 1).count > 1 ? String($0.split(separator: "/")[0]) : "" }
            .sorted { $0.key < $1.key }
    }

    var body: some View {
        Menu {
            Button("Default") { draft = "" }
            ForEach(groups, id: \.0) { provider, models in
                Section(provider) {
                    ForEach(models, id: \.self) { model in
                        Button {
                            draft = model
                        } label: {
                            if model == draft { Label(model, systemImage: "checkmark") } else { Text(model) }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.up.chevron.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Models this agent CLI lists")
    }
}

/// Name → folder rows, for repos.
private struct MapEditor: View {
    let field: ConfigFields.Field
    let label: TitleLabel
    let store: Store
    @State private var newName = ""
    @State private var newPath = ""

    private var map: [String: JSON] {
        if case .object(let map)? = store.value(field.key) { return map }
        return [:]
    }

    var body: some View {
        label
        ForEach(map.keys.sorted(), id: \.self) { name in
            HStack {
                Text(name).fontWeight(.medium).frame(width: 110, alignment: .leading)
                Text(map[name]?.string ?? "").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { edit { $0[name] = nil } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove \(name)")
            }
        }
        HStack {
            TextField("", text: $newName, prompt: Text("name")).frame(width: 110)
            TextField("", text: $newPath, prompt: Text("~/path/to/repo"))
            Button("Choose…") { choose() }
            Button("Add") {
                edit { $0[newName] = .string(newPath) }
                newName = ""; newPath = ""
            }
            .disabled(newName.isEmpty || newPath.isEmpty)
        }
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
    }

    private func edit(_ change: (inout [String: JSON]) -> Void) {
        var map = map
        change(&map)
        store.edit(field.key, .object(map))
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        newPath = url.path.abbreviatingHome
        if newName.isEmpty { newName = url.lastPathComponent.lowercased() }
    }
}

/// Free-form JSON object, for claude_settings.
private struct JSONEditor: View {
    let field: ConfigFields.Field
    let label: TitleLabel
    let store: Store
    @State private var draft = ""

    private static func parse(_ text: String) -> JSON? {
        let value = try? JSONDecoder().decode(JSON.self, from: Data(text.utf8))
        if case .object? = value { return value }
        return nil
    }

    var body: some View {
        label
        TextEditor(text: $draft)
            .font(.callout.monospaced())
            .frame(minHeight: 90)
            .scrollContentBackground(.hidden)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6).fill(.background.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(store.invalid.contains(field.key) ? AnyShapeStyle(.red) : AnyShapeStyle(.separator)))
            .onChange(of: draft) { _, text in
                if let value = Self.parse(text) {
                    store.invalid.remove(field.key)
                    store.edit(field.key, value)
                } else {
                    store.invalid.insert(field.key)
                }
            }
            .onChange(of: store.value(field.key), initial: true) { _, value in
                if Self.parse(draft) != value { draft = value?.text(pretty: true) ?? "{}" }
            }
            // Revert also throws away text that never parsed
            .onChange(of: store.reverts) { draft = store.value(field.key)?.text(pretty: true) ?? "{}" }
        if store.invalid.contains(field.key) {
            Text("Not valid JSON yet; it needs to be an object like {\"key\": \"value\"}.").font(.caption).foregroundStyle(.red)
        }
    }
}
