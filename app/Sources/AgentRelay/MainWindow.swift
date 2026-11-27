import AppKit
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case general = "General"
    case activity = "Activity"
    case workers = "Workers"
    case connectors = "Connectors"
    case memory = "Memory"
    case doctor = "Doctor"

    var id: String { rawValue }

    static let primaryItems: [SidebarItem] = [.general, .activity, .workers, .connectors, .memory]
    static let settingsItems: [SidebarItem] = [.doctor]

    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .activity: "waveform.path.ecg"
        case .workers: "hammer.fill"
        case .connectors: "powerplug.fill"
        case .memory: "brain.head.profile"
        case .doctor: "stethoscope"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .activity: .blue
        case .workers: .orange
        case .connectors: .green
        case .memory: .pink
        case .doctor: .red
        }
    }

    /// Gray reads as white on a dark tile; give it a lighter glyph.
    var glyphTint: Color { self == .general ? Color(white: 0.75) : tint }

    var summary: String {
        switch self {
        case .general: "Start the relay and choose where it listens, how you call it, and which agents answer."
        case .activity: "Every answer and worker as it runs, with what its agent is doing right now. Open one to follow each step, or stop it."
        case .workers: "Agents started in a repo. Each keeps its own session between turns."
        case .connectors: "Tools the agents reach through their own CLIs. Each check runs the CLI's sign-in status; no token is shown."
        case .memory: "MEMORY.md in the dispatcher's working folder. The dispatcher reads it every turn and keeps it under the limit."
        case .doctor: "Checks that the relay can run: tools installed, config valid, Slack login and channel, agents and repos."
        }
    }

    private var keywords: [String] {
        switch self {
        case .general: ["status", "serve", "start", "stop", "channel", "trigger", "icon", "emoji", "opencode", "claude", "pi", "model", "runner", "dispatcher", "repos", "config", "settings"]
        case .activity: ["running", "stop", "cancel", "kill", "stream", "feed", "steps", "tools", "answer"]
        case .workers: ["session", "task", "repo", "log"]
        case .connectors: ["slack", "github", "jira", "datadog", "grafana", "clickhouse", "token", "auth"]
        case .memory: ["memory.md", "notes"]
        case .doctor: ["health", "check"]
        }
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || rawValue.lowercased().contains(q) || keywords.contains { $0.contains(q) }
    }
}

/// Rounded-square icon: white glyph on a colored gradient in light mode, colored glyph on a dark tile in dark mode.
struct IconTile: View {
    var icon: String
    var tint: Color
    var glyphTint: Color
    var size: CGFloat = 20
    @Environment(\.colorScheme) private var colorScheme

    init(item: SidebarItem, size: CGFloat = 20) {
        self.init(icon: item.icon, tint: item.tint, glyphTint: item.glyphTint, size: size)
    }

    init(icon: String, tint: Color, glyphTint: Color? = nil, size: CGFloat = 20) {
        self.icon = icon
        self.tint = tint
        self.glyphTint = glyphTint ?? tint
        self.size = size
    }

    var body: some View {
        let dark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        ZStack {
            if dark {
                shape.fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.10)], startPoint: .top, endPoint: .bottom))
            } else {
                shape.fill(tint.gradient)
            }
            Image(systemName: icon)
                .font(.system(size: size * 0.52, weight: .semibold))
                .foregroundStyle(dark ? glyphTint : .white)
        }
        .frame(width: size, height: size)
        .overlay(shape.strokeBorder(.white.opacity(dark ? 0.10 : 0.12), lineWidth: 0.5))
    }
}

/// System Settings-style row: solid accent fill when selected, gray when the window is inactive.
struct SidebarRow: View {
    let item: SidebarItem
    let isSelected: Bool
    var badge: Int = 0
    var badgeColor: Color = .orange
    let action: () -> Void
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let highlighted = isSelected && activeState != .inactive
        Button(action: action) {
            HStack(spacing: 6) {
                Label {
                    Text(item.rawValue).lineLimit(1)
                } icon: {
                    IconTile(item: item)
                }
                Spacer(minLength: 0)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(highlighted ? Color.accentColor : .white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(highlighted ? Color.white : badgeColor))
                }
            }
            .foregroundStyle(highlighted ? Color.white : Color.primary)
            .padding(.leading, 2)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? (activeState == .inactive ? Color.primary.opacity(0.12) : Color.accentColor) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
        .listRowSeparator(.hidden)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

@MainActor
@Observable
final class Navigation {
    var selected: SidebarItem = .general {
        didSet {
            guard selected != oldValue, !moving else { return }
            back.append(oldValue)
            forward.removeAll()
        }
    }
    private var back: [SidebarItem] = []
    private var forward: [SidebarItem] = []
    private var moving = false

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    func goBack() { step(from: &back, to: &forward) }
    func goForward() { step(from: &forward, to: &back) }

    private func step(from: inout [SidebarItem], to: inout [SidebarItem]) {
        guard let item = from.popLast() else { return }
        to.append(selected)
        moving = true
        selected = item
        moving = false
    }
}

struct MainWindowView: View {
    @Bindable var nav: Navigation
    let store: Store
    @State private var search = ""

    static let sidebarWidth: CGFloat = 220

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List {
                Section {
                    ForEach(SidebarItem.primaryItems.filter { $0.matches(search) }) { row($0) }
                }
                Section {
                    ForEach(SidebarItem.settingsItems.filter { $0.matches(search) }) { row($0) }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $search, placement: .sidebar, prompt: "Search")
            .safeAreaInset(edge: .bottom) { RelayFooter(store: store) }
            .navigationSplitViewColumnWidth(min: Self.sidebarWidth, ideal: Self.sidebarWidth, max: Self.sidebarWidth)
            .frame(width: Self.sidebarWidth)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            PaneView(item: nav.selected, store: store, nav: nav)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        ControlGroup {
                            Button { nav.goBack() } label: { Label("Back", systemImage: "chevron.backward") }
                                .disabled(!nav.canGoBack)
                                .keyboardShortcut("[", modifiers: .command)
                            Button { nav.goForward() } label: { Label("Forward", systemImage: "chevron.forward") }
                                .disabled(!nav.canGoForward)
                                .keyboardShortcut("]", modifiers: .command)
                        }
                        .controlGroupStyle(.navigation)
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 860, minHeight: 560)
        .task {
            // Connector badges should show without opening the pane. Status polling starts with the
            // menu bar icon, so it keeps going after this window closes.
            if store.connectors == nil { await store.checkConnectors() }
            if store.fields == nil { await store.loadFields() }
        }
    }

    private func row(_ item: SidebarItem) -> some View {
        SidebarRow(
            item: item,
            isSelected: nav.selected == item,
            badge: item == .activity ? store.runningCount : item == .workers ? store.waitingCount : item == .connectors ? store.failingConnectors : 0,
            badgeColor: item == .activity ? .blue : item == .connectors ? .red : .orange
        ) { nav.selected = item }
    }
}

/// Bottom of the sidebar: is the relay listening.
struct RelayFooter: View {
    let store: Store

    var body: some View {
        let running = store.status?.serve.running == true
        HStack(spacing: 8) {
            Circle()
                .fill(store.status == nil ? Color.gray : running ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
                .shadow(color: running ? .green.opacity(0.6) : .clear, radius: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.status == nil ? "Reading status…" : running ? "Relay running" : "Relay stopped")
                    .font(.callout.weight(.medium))
                if running, store.runningCount > 0 {
                    Text("\(store.runningCount) running")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let busy = store.status?.serve.busy {
                    Text("\(busy.label) is working")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if running, let poll = store.status?.serve.lastPoll {
                    Text("Checked Slack \(poll.relativeTime)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// The detail pane for a sidebar item, with Hush's header section on top.
struct PaneView: View {
    let item: SidebarItem
    let store: Store
    let nav: Navigation

    var body: some View {
        Group {
            switch item {
            case .general: GeneralPane(store: store)
            case .activity: ActivityPane(store: store)
            case .workers: WorkersPane(store: store)
            case .connectors: ConnectorsPane(store: store)
            case .memory: MemoryPane(store: store)
            case .doctor: DoctorPane(store: store)
            }
        }
        .navigationTitle(item.rawValue)
    }
}

struct PaneHeader: View {
    let item: SidebarItem

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                IconTile(item: item, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.rawValue).font(.headline)
                    Text(item.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// Title over a secondary description, the label style Hush uses in forms.
struct TitleLabel: View {
    var title: String
    var description: String?
    /// Changed in the form and not saved yet
    var edited = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                if edited {
                    Circle().fill(.tint).frame(width: 6, height: 6).help("Not saved yet")
                }
            }
            if let description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct StatusDot: View {
    var ok: Bool?
    var checking = false

    var body: some View {
        if checking {
            ProgressView().controlSize(.small).frame(width: 16, height: 16)
        } else {
            Image(systemName: ok == nil ? "minus.circle" : ok! ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(ok == nil ? Color.secondary : ok! ? Color.green : Color.red)
                .frame(width: 16, height: 16)
        }
    }
}

struct Pill: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

func reveal(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}

func openFile(_ path: String) {
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
