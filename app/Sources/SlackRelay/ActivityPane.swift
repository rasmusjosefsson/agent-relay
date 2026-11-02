import SwiftUI

extension String {
    /// A model's answer with its inline Markdown (**bold**, `code`, links) rendered; the plain text if it doesn't parse.
    var markdown: AttributedString {
        (try? AttributedString(markdown: self, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(self)
    }
}

extension Run {
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

/// Every dispatcher answer and worker: what its agent is doing now, a live feed of its steps, and Stop.
struct ActivityPane: View {
    let store: Store
    @State private var expanded = Set<String>()

    var body: some View {
        Form {
            PaneHeader(item: .activity)
            let conversations = store.conversations
            let running = conversations.filter(\.isActive)
            let recent = conversations.filter { !$0.isActive }.prefix(15)
            Section {
                if running.isEmpty {
                    Text("Nothing is running. Write \(store.trigger)\(store.status?.dispatcher.label ?? "boss") … in Slack and it shows up here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(running) { conversation($0) }
            } header: {
                Text(running.isEmpty ? "Running" : "Running (\(store.runningCount))")
            }
            if !recent.isEmpty {
                Section("Recent") {
                    ForEach(Array(recent)) { conversation($0) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // follow the newest running one straight away
            if expanded.isEmpty, let newest = store.runs.first(where: \.isActive) { expanded.insert(newest.id) }
        }
    }

    @ViewBuilder
    private func conversation(_ conversation: Conversation) -> some View {
        if conversation.isThread {
            ThreadCard(store: store, conversation: conversation) { card($0, showOrigin: false) }
        } else if let run = conversation.runs.first {
            card(run)
        }
    }

    private func card(_ run: Run, showOrigin: Bool = true) -> some View {
        RunCard(store: store, run: run, showOrigin: showOrigin, expanded: Binding(
            get: { expanded.contains(run.id) },
            set: { if $0 { expanded.insert(run.id) } else { expanded.remove(run.id) } }
        ))
    }
}

struct RunCard: View {
    let store: Store
    let run: Run
    /// Off inside a thread, whose header says where it is
    var showOrigin = true
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 12)
                        Text(run.label).font(.headline)
                        Text(run.kind == .answer ? "answer" : "worker\(run.repo.map { " · \($0)" } ?? "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Pill(text: run.status, color: run.statusColor)
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Hide steps" : "Show every step")
                Elapsed(run: run)
                if run.isActive {
                    let stopping = store.stopping.contains(run.id)
                    Button(stopping ? "Stopping…" : "Stop", role: .destructive) { Task { await store.cancel(run) } }
                        .disabled(stopping)
                        .help(run.kind == .answer
                              ? "End this answer and its agent; its Slack post turns into \"Stopped.\""
                              : "End this worker's turn; \(store.trigger)\(run.label) … picks it up again in the same session")
                }
            }
            if showOrigin && !run.context.isEmpty {
                ThreadContext(lines: run.context)
                    .padding(.leading, 20)
            }
            if !run.text.isEmpty {
                Text(run.text)
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 2)
                    .textSelection(.enabled)
                    .padding(.leading, 20)
            }
            if showOrigin {
                Origin(store: store, run: run)
                    .padding(.leading, 20)
            }
            if run.isActive && !expanded {
                Group {
                    if let last = run.last {
                        ActivityLine(row: last, lineLimit: 1)
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(run.status == "waiting" ? "Waiting for your reply in Slack" : "Starting…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.leading, 20)
            } else if !run.isActive && !expanded, let answer = run.answer, !answer.isEmpty {
                Text(answer.markdown)
                    .font(.callout)
                    .lineLimit(2)
                    .padding(.leading, 20)
            }
            if let error = store.runErrors[run.id] {
                Text(error).font(.callout).foregroundStyle(.red).padding(.leading, 20)
            }
            if expanded {
                ActivityFeed(store: store, run: run)
                    .padding(.leading, 20)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Several runs from one Slack thread: where it is and how many, then each message's card, oldest first.
struct ThreadCard<Card: View>: View {
    let store: Store
    let conversation: Conversation
    @ViewBuilder let card: (Run) -> Card

    var body: some View {
        let newest = conversation.runs.last!
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(.secondary)
                Text("Thread").font(.headline)
                Text("\(conversation.runs.count) messages").font(.caption).foregroundStyle(.secondary)
                if conversation.isActive { Pill(text: "running", color: .blue) }
                Spacer()
                if let link = conversation.slackLink(base: store.status?.serve.slackUrl) {
                    Button { NSWorkspace.shared.open(link) } label: { Label("Open in Slack", systemImage: "arrow.up.right.square") }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help(link.absoluteString)
                }
            }
            Origin(store: store, run: newest, showLink: false)
            if let context = conversation.runs.first?.context, !context.isEmpty {
                ThreadContext(lines: context)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(conversation.runs) { run in card(run) }
            }
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                Rectangle().fill(.separator).frame(width: 2)
            }
        }
        .padding(.vertical, 3)
    }
}

/// The messages above a question in its Slack thread, so you see what it answered; click one to read all of it.
struct ThreadContext: View {
    let lines: [ContextLine]
    @State private var open = Set<Int>()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: line.from == "bot" ? "bolt.fill" : line.from == "other" ? "person" : "person.fill")
                        .foregroundStyle(line.from == "bot" ? Color.orange : Color.secondary)
                        .frame(width: 14)
                        .help(line.from == "bot" ? "A bot or app posted this" : line.from == "other" ? "Someone else wrote this" : "You or your agent")
                    Text(Self.plain(line.text))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(open.contains(i) ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .contentShape(Rectangle())
                .onTapGesture { if open.contains(i) { open.remove(i) } else { open.insert(i) } }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    /// Slack's <url|label> and <url> as just the label or the url
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: #"<([^|>]+)\|([^>]+)>"#, with: "$2", options: .regularExpression)
            .replacingOccurrences(of: #"<([^>]+)>"#, with: "$1", options: .regularExpression)
    }
}

/// Where a run came from and where it works: "#rasmus-agent · in a thread · claude haiku · ~/slack-agent", and a link to the message.
struct Origin: View {
    let store: Store
    let run: Run
    var showLink = true

    var body: some View {
        let channel = run.channel.flatMap { id in (store.channelNames[id] ?? nil) ?? id }
        let inThread = run.thread.map { $0 != "-" && !$0.isEmpty } ?? false
        let parts = [channel.map { inThread ? "\($0) · in a thread" : $0 }, run.agent, run.dir?.abbreviatingHome].compactMap { $0 }.filter { !$0.isEmpty }
        HStack(spacing: 6) {
            Image(systemName: "number").foregroundStyle(.tertiary)
            Text(parts.joined(separator: " · "))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if showLink, let link = run.slackLink(base: store.status?.serve.slackUrl) {
                Button { NSWorkspace.shared.open(link) } label: {
                    Label("Open in Slack", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.link)
                .help(link.absoluteString)
            }
        }
        .font(.caption)
    }
}

/// How long a run has been going, ticking while it runs; when it finished otherwise.
struct Elapsed: View {
    let run: Run

    var body: some View {
        Group {
            if run.isActive, let start = ISO8601DateFormatter().date(from: run.started) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.duration(context.date.timeIntervalSince(start)))
                }
            } else if let finished = run.finished {
                Text(finished.relativeTime)
            }
        }
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s < 3600 ? String(format: "%d:%02d", s / 60, s % 60) : String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}

/// The steps a run's agent took, reloaded every second and a half while it runs, newest at the bottom.
struct ActivityFeed: View {
    let store: Store
    let run: Run
    @State private var rows: [ActivityRow]?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let rows {
                        if rows.isEmpty {
                            Text(run.isActive ? "No steps yet. Claude and OpenCode report each one as it finishes; Pi only reports its answer." : "No steps recorded.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                            ActivityLine(row: row).id(i)
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    // the reply as posted, unless the agent's own text already shows it
                    if !run.isActive, let answer = run.answer, !answer.isEmpty, rows?.contains(where: { $0.kind == "text" }) != true {
                        Label {
                            Text(answer.markdown).textSelection(.enabled)
                        } icon: {
                            Image(systemName: "paperplane.fill").foregroundStyle(.green)
                        }
                        .font(.callout)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // grows with its steps up to a scrolling 420pt; a line is about 26pt
            .frame(height: min(420, max(72, CGFloat(rows?.count ?? 0) * 26 + 40)))
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
            .onChange(of: rows?.count) { proxy.scrollTo("end", anchor: .bottom) }
        }
        // restarts when the run finishes, so the final steps load once more
        .task(id: run.isActive) {
            repeat {
                if let loaded = await store.activity(run.id), loaded != rows { rows = loaded }
                guard run.isActive else { break }
                try? await Task.sleep(for: .seconds(1.5))
            } while !Task.isCancelled
        }
    }
}

/// One step; click a step with more to it (the prompt, a tool's input or output) to see all of it.
struct ActivityLine: View {
    let row: ActivityRow
    var lineLimit: Int?
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 14)
                Text(row.text)
                    .font(row.kind == "tool" ? .callout.monospaced() : row.kind == "output" ? .caption.monospaced() : .callout)
                    .foregroundStyle(row.kind == "error" ? Color.red : ["output", "thinking", "done", "start"].contains(row.kind) ? Color.secondary : Color.primary)
                    .italic(row.kind == "thinking")
                    .lineLimit(lineLimit)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                if hasDetail {
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
            }
            .padding(.leading, row.kind == "output" ? 20 : 0)
            .contentShape(Rectangle())
            .onTapGesture { if hasDetail { open.toggle() } }
            .help(hasDetail ? (open ? "Hide" : row.kind == "relay" ? "Show the command and the whole prompt" : "Show all of it") : "")
            if open, let detail = row.detail {
                ScrollView {
                    Text(detail)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 240)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05)))
                .padding(.leading, 20)
            }
        }
    }

    private var hasDetail: Bool { lineLimit == nil && !(row.detail ?? "").isEmpty }

    private var icon: String {
        switch row.kind {
        case "relay": "arrow.right.circle"
        case "start": "cpu"
        case "thinking": "brain"
        case "tool": "terminal"
        case "output": "arrow.turn.down.right"
        case "error": "exclamationmark.triangle.fill"
        case "done": "checkmark.circle.fill"
        default: "text.bubble"
        }
    }

    private var color: Color {
        switch row.kind {
        case "relay": .purple
        case "start": .secondary
        case "thinking": .pink
        case "tool": .blue
        case "error": .red
        case "done": .green
        default: .secondary
        }
    }
}
