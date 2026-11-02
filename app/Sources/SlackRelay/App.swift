import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            // Render every pane to PNG, light and dark, then quit
            app.setActivationPolicy(.prohibited)
            let dir = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor in
                await Snapshot.run(into: dir)
                exit(0)
            }
            app.run()
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private let nav = Navigation()
    private lazy var store = Store(cli: ShellCLI.locate())
    private var statusItem: StatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.menu()
        store.startPolling()
        statusItem = StatusItem(store: store) { [weak self] pane in
            if let pane { self?.nav.selected = pane }
            self?.showWindow()
        }
        showWindow()
    }

    /// The menu bar icon stays after the window closes, so the relay can be off and still have a place in the bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    private func showWindow() {
        let window = self.window ?? makeWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { MainWindow.pinSidebar(in: window) }
    }

    private func makeWindow() -> NSWindow {
        let window = MainWindow.make(root: MainWindowView(nav: nav, store: store))
        window.title = nav.selected.rawValue
        window.setFrameAutosaveName("SlackRelayMain")
        window.delegate = self
        withObservationTracking { _ = nav.selected } onChange: { [weak self] in
            Task { @MainActor in self?.trackTitle() }
        }
        self.window = window
        return window
    }

    private func trackTitle() {
        window?.title = nav.selected.rawValue
        withObservationTracking { _ = nav.selected } onChange: { [weak self] in
            Task { @MainActor in self?.trackTitle() }
        }
    }

    func windowDidBecomeMain(_ notification: Notification) {
        MainWindow.pinSidebar(in: window)
        Task { await store.refreshStatus() }
    }

    private static func menu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Slack Relay", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Slack Relay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        // Edit menu so copy, paste and undo work in text fields
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        return main
    }
}

@MainActor
enum MainWindow {
    static func make<V: View>(root: V) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = NSHostingController(rootView: root)
        window.minSize = NSSize(width: 860, height: 560)
        // System Settings-style chrome: sidebar under the traffic lights, title in the toolbar,
        // and scrolled content blurs beneath it (titlebar must stay non-transparent)
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.toolbar = NSToolbar(identifier: "MainWindowToolbar")
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    /// Fix the sidebar at its width; the split view's delegate is an NSSplitViewController.
    static func pinSidebar(in window: NSWindow?) {
        guard let split = findSplitView(in: window?.contentView),
              let controller = split.delegate as? NSSplitViewController,
              let sidebar = controller.splitViewItems.first else { return }
        sidebar.canCollapse = false
        sidebar.canCollapseFromWindowResize = false
        sidebar.minimumThickness = MainWindowView.sidebarWidth
        sidebar.maximumThickness = MainWindowView.sidebarWidth
    }

    private static func findSplitView(in view: NSView?) -> NSSplitView? {
        guard let view else { return nil }
        if let split = view as? NSSplitView { return split }
        for subview in view.subviews {
            if let found = findSplitView(in: subview) { return found }
        }
        return nil
    }
}

/// `SlackRelay --snapshot <dir>`: each pane against the real CLI, written as <pane>-light.png and <pane>-dark.png.
/// Uses cacheDisplay rather than ImageRenderer, which leaves Forms blank.
@MainActor
enum Snapshot {
    static func run(into dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = Store(cli: ShellCLI.locate())
        await store.refreshStatus()
        async let c: Void = store.checkConnectors()
        async let m: Void = store.loadMemory()
        async let d: Void = store.runDoctor()
        async let f: Void = store.loadFields()
        _ = await (c, m, d, f)
        for item in SidebarItem.allCases {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let nav = Navigation()
                nav.selected = item
                let window = MainWindow.make(root: MainWindowView(nav: nav, store: store))
                window.setContentSize(NSSize(width: 980, height: Double(ProcessInfo.processInfo.environment["SNAPSHOT_HEIGHT"] ?? "") ?? 680))
                window.appearance = NSAppearance(named: appearance)
                window.title = item.rawValue
                window.orderFront(nil)
                MainWindow.pinSidebar(in: window)
                try? await Task.sleep(for: .milliseconds(700))
                guard let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let file = dir.appendingPathComponent("\(item.rawValue.lowercased())-\(name).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: file)
                print(file.path)
                window.close()
            }
        }
    }
}
