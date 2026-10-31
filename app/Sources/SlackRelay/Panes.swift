import SwiftUI

extension Worker {
    var statusColor: Color {
        switch status {
        case "running": .blue
        case "waiting": .orange
        case "done": .green
        case "failed", "died": .red
        default: .secondary
        }
    }
}

// MARK: - Workers

struct WorkersPane: View {
    let store: Store
    @State private var stopping: Worker?

    var body: some View {
        Form {
            PaneHeader(item: .workers)
            let workers = (store.status?.workers ?? []).sorted { a, b in
                a.isActive != b.isActive ? a.isActive : (a.started ?? "") > (b.started ?? "")
            }
            if workers.isEmpty {
                Section {
                    Text("No workers yet. Ask the dispatcher in Slack, e.g. \(store.trigger)fix the flaky test in client.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(workers) { worker in
                Section {
                    HStack(spacing: 8) {
                        Text(worker.name).font(.headline)
                        Pill(text: worker.status, color: worker.statusColor)
                        Spacer()
                        if let log = worker.log {
                            Button("Open log") { openFile(log) }
                        }
                        Button("Remove") {
                            if worker.isActive { stopping = worker } else { Task { await store.removeWorker(worker.name) } }
                        }
                        .help(worker.isActive ? "Stop it and forget it" : "Forget it, so \(store.trigger)\(worker.name) can't resume it")
                    }
                    if let error = store.workerErrors[worker.name] {
                        Text(error).font(.callout).foregroundStyle(.red)
                    }
                    if let task = worker.task, !task.isEmpty {
                        Text(task).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                    }
                    LabeledContent("Agent", value: [worker.runner, worker.model.flatMap { $0.isEmpty ? nil : $0 }].compactMap { $0 }.joined(separator: " · "))
                    if let dir = worker.dir {
                        LabeledContent("Repo", value: "\(worker.repo ?? "") · \(dir.abbreviatingHome)")
                    }
                    if let session = worker.session, !session.isEmpty {
                        LabeledContent("Session") {
                            HStack(spacing: 6) {
                                Text(session).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                                Button { copyToPasteboard(session) } label: { Image(systemName: "doc.on.doc") }
                                    .buttonStyle(.borderless)
                                    .help("Copy session ID")
                            }
                        }
                    }
                    LabeledContent("Turns", value: "\(worker.turns ?? 0)")
                    LabeledContent("Started", value: worker.started?.relativeTime ?? "–")
                    if let finished = worker.finished {
                        LabeledContent("Finished", value: finished.relativeTime)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Stop \(stopping?.name ?? "")?", isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }), presenting: stopping) { worker in
            Button("Stop and Remove", role: .destructive) { Task { await store.removeWorker(worker.name) } }
        } message: { worker in
            Text("\(worker.name) is \(worker.status). Its agent is stopped and its log deleted.")
        }
    }
}

// MARK: - Connectors

struct ConnectorsPane: View {
    let store: Store
    @State private var editing: String?
    @State private var draft = ""

    var body: some View {
        Form {
            PaneHeader(item: .connectors)
            Section {
                if let connectors = store.connectors {
                    ForEach(connectors) { row($0) }
                } else {
                    HStack { ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(.secondary) }
                }
            } header: {
                HStack {
                    Text("Sign-in")
                    Spacer()
                    Button("Check all") { Task { await store.checkConnectors() } }
                        .disabled(!store.checking.isEmpty)
                }
            } footer: {
                Text("A check is a shell command: exit 0 means signed in, and its first line is shown with anything token-like removed. Clear a check to turn the connector off. Add more with slack-relay config set connectors.<name> '{\"title\": …, \"check\": …}'.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .task { if store.connectors == nil { await store.checkConnectors() } }
    }

    @ViewBuilder
    private func row(_ c: Connector) -> some View {
        let checking = store.checking.contains(c.name) || store.checking.contains("*")
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                StatusDot(ok: c.ok, checking: checking)
                TitleLabel(title: c.title, description: c.ok == nil ? "off" : c.detail)
                Spacer()
                if c.builtin != true {
                    Button(editing == c.name ? "Done" : "Edit") {
                        if editing == c.name { editing = nil } else { editing = c.name; draft = c.check }
                    }
                    .buttonStyle(.borderless)
                }
                Button("Recheck") { Task { await store.checkConnectors([c.name]) } }
                    .disabled(checking)
            }
            if editing == c.name {
                TextField("Check command", text: $draft, axis: .vertical)
                    .font(.callout.monospaced())
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { save(c) }
                HStack {
                    if let error = store.fieldErrors["connectors.\(c.name).check"] {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    Spacer()
                    Button("Cancel") { editing = nil }
                    Button("Save and check") { save(c) }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func save(_ c: Connector) {
        Task {
            if await store.set("connectors.\(c.name).check", string: draft) {
                editing = nil
                await store.checkConnectors([c.name])
            }
        }
    }
}

// MARK: - Memory

struct MemoryPane: View {
    let store: Store
    @State private var draft = ""
    @State private var loaded: String?

    var body: some View {
        Form {
            PaneHeader(item: .memory)
            if let memory = store.memory {
                let lines = draft.isEmpty ? 0 : draft.split(separator: "\n", omittingEmptySubsequences: false).count
                Section {
                    LabeledContent {
                        HStack(spacing: 8) {
                            Gauge(value: Double(min(lines, memory.limit)), in: 0...Double(max(memory.limit, 1))) {}
                                .gaugeStyle(.accessoryLinearCapacity)
                                .tint(lines > memory.limit ? .red : .accentColor)
                                .frame(width: 120)
                            Text("\(lines) / \(memory.limit) lines").monospacedDigit()
                                .foregroundStyle(lines > memory.limit ? .red : .secondary)
                        }
                    } label: {
                        TitleLabel(title: "MEMORY.md", description: memory.exists ? memory.path.abbreviatingHome : "Not created yet; the dispatcher writes it when it learns something.")
                    }
                    TextEditor(text: $draft)
                        .font(.body.monospaced())
                        .frame(minHeight: 280)
                        .scrollContentBackground(.hidden)
                        .overlay(alignment: .topLeading) {
                            if draft.isEmpty {
                                Text("Empty. Notes the dispatcher should remember across messages go here.")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 1)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                    HStack {
                        if let error = store.memoryError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                        if memory.exists {
                            Button("Show in Finder") { reveal(memory.path) }.buttonStyle(.link)
                        }
                        Spacer()
                        Button("Revert") { draft = memory.text }.disabled(draft == memory.text)
                        Button("Save") { Task { await store.saveMemory(draft) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(draft == memory.text)
                            .keyboardShortcut("s", modifiers: .command)
                    }
                }
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .formStyle(.grouped)
        .task { await store.loadMemory() }
        .onChange(of: store.memory?.text, initial: true) { _, text in
            // Take the file's text unless there are unsaved edits
            guard let text else { return }
            if loaded == nil || draft == loaded { draft = text }
            loaded = text
        }
    }
}

// MARK: - Doctor

struct DoctorPane: View {
    let store: Store

    var body: some View {
        Form {
            PaneHeader(item: .doctor)
            Section {
                if let checks = store.doctor {
                    ForEach(checks) { check in
                        HStack(alignment: .top, spacing: 10) {
                            StatusDot(ok: check.ok)
                            TitleLabel(title: check.check, description: check.detail.abbreviatingHome)
                                .textSelection(.enabled)
                        }
                    }
                } else {
                    HStack { ProgressView().controlSize(.small); Text("Running checks…").foregroundStyle(.secondary) }
                }
            } header: {
                HStack {
                    if let checks = store.doctor {
                        let failed = checks.filter { !$0.ok }.count
                        Text(failed == 0 ? "All \(checks.count) checks pass" : "\(failed) of \(checks.count) checks fail")
                    } else {
                        Text("Checks")
                    }
                    Spacer()
                    Button("Run again") { Task { await store.runDoctor() } }.disabled(store.doctorRunning)
                }
            }
        }
        .formStyle(.grouped)
        .task { if store.doctor == nil { await store.runDoctor() } }
    }
}
