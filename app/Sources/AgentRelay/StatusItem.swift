import AppKit
import Observation

/// Menu bar icon for as long as the app is open. Waves while the relay is listening, slashed while it is stopped.
@MainActor
final class StatusItem: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let store: Store
    private let open: (SidebarItem?) -> Void
    private var symbol: String?

    /// `open` shows the window, on the given pane when there is one.
    init(store: Store, open: @escaping (SidebarItem?) -> Void) {
        self.store = store
        self.open = open
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        apply()
    }

    private func apply() {
        updateImage()
        withObservationTracking { [store] in
            _ = store.status
            _ = store.serveAction
            _ = store.statusError
        } onChange: { [weak self] in
            Task { @MainActor in self?.apply() }
        }
    }

    private func updateImage() {
        let running = store.status?.serve.running == true
        let name = running
            ? "antenna.radiowaves.left.and.right"
            : "antenna.radiowaves.left.and.right.slash"
        let label = store.status == nil ? "Agent Relay" : running ? "Agent Relay, running" : "Agent Relay, stopped"
        item.button?.toolTip = label
        item.button?.setAccessibilityLabel(label)
        guard name != symbol else { return }
        symbol = name
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: label) else { return }
        let image = base.withSymbolConfiguration(config) ?? base
        image.isTemplate = true
        item.button?.image = image
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(.sectionHeader(title: headline))
        if let error = store.serveError ?? (store.status == nil ? store.statusError : nil), !error.isEmpty {
            let line = NSMenuItem(title: Self.oneLine(error), action: nil, keyEquivalent: "")
            line.isEnabled = false
            menu.addItem(line)
        }
        menu.addItem(.separator())
        let running = store.runs.filter(\.isActive)
        for run in running {
            let entry = NSMenuItem(title: Self.oneLine("\(run.label): \(run.text)"), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let step = NSMenuItem(title: Self.oneLine(run.last?.text ?? (run.status == "waiting" ? "Waiting for your reply" : "Starting…")), action: nil, keyEquivalent: "")
            step.isEnabled = false
            sub.addItem(step)
            sub.addItem(.separator())
            sub.addItem(item("Show in Activity", #selector(openActivity(_:))))
            let stop = item("Stop", #selector(stopRun(_:)))
            stop.representedObject = run.id
            sub.addItem(stop)
            entry.submenu = sub
            menu.addItem(entry)
        }
        if !running.isEmpty { menu.addItem(.separator()) }
        menu.addItem(item("Open Agent Relay", #selector(openWindow(_:))))
        if let action = store.serveAction {
            let busy = NSMenuItem(title: action == "start" ? "Starting…" : "Stopping…", action: nil, keyEquivalent: "")
            busy.isEnabled = false
            menu.addItem(busy)
        } else if store.status?.serve.running == true {
            menu.addItem(item("Stop Relay", #selector(stopRelay(_:))))
        } else {
            menu.addItem(item("Start Relay", #selector(startRelay(_:))))
        }
        menu.addItem(.separator())
        menu.addItem(item("Quit Agent Relay", #selector(quit(_:))))
    }

    private var headline: String {
        guard let status = store.status else {
            return store.statusError == nil ? "Reading status…" : "Can't read status"
        }
        if status.serve.running {
            let count = store.runningCount
            if count > 0 { return "\(count) running" }
            if let busy = status.serve.busy { return "\(busy.label) is working" }
            return "Relay running"
        }
        return "Relay stopped"
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private static func oneLine(_ text: String) -> String {
        let line = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }

    @objc private func openWindow(_ sender: Any?) { open(nil) }
    @objc private func openActivity(_ sender: Any?) { open(.activity) }
    @objc private func startRelay(_ sender: Any?) { Task { await store.startServe() } }
    @objc private func stopRelay(_ sender: Any?) { Task { await store.stopServe() } }
    @objc private func stopRun(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let run = store.runs.first(where: { $0.id == id }) else { return }
        Task { await store.cancel(run) }
    }
    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }
}
