import SwiftUI
import AppKit
import Combine
import VibeBuddyCore

// Menu-bar agent (LSUIElement in project.yml): no Dock icon, no app menu
// bar. AppKit owns the lifecycle so the status item can open the main
// window on a plain click — SwiftUI's MenuBarExtra only offers a menu or
// a popover, and SwiftUI can't open a Window/Settings scene from AppKit.
// All wiring happens at launch, independent of any window being open.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private let state = AppState()
    // BLE and the AudioSourceCoordinator share a single BLEController
    // instance — the coordinator drives mode switching, while BLE keeps
    // owning its CoreBluetooth stack.
    private let ble: BLEController
    private let coord: AudioSourceCoordinator

    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    override init() {
        ble = BLEController(textHandler: TextInjector())
        coord = AudioSourceCoordinator(ble: ble)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        setUpStatusItem()

        ble.bind(state: state)
        coord.bind(state: state)
        // Bridge the macOS-only focus-gate signal up to AppState so
        // ContentView can show "typing paused" when the session starts
        // with focus on a non-editable control.
        if let injector = ble.audio.textHandler as? TextInjector {
            injector.onFocusChange = { [weak state] editable, desc in
                state?.focusEditable = editable
                state?.focusDescription = desc
            }
        }

        // Front-app -> device. Push as a JSON line on the same RX
        // characteristic the device uses for control frames.
        FrontAppMonitor.shared.onChange = { [weak ble] name in
            guard let ble else { return }
            let line = "{\"type\":\"front_app\",\"name\":\"\(jsonEscape(name))\"}\n"
            if let data = line.data(using: .utf8) {
                ble.write(data)
            }
        }
        FrontAppMonitor.shared.start()

        // mtu transitions 0 -> non-zero exactly when the device sends its
        // first {"type":"link",...} message, which means rxCharacteristic
        // is bound and writes will land. Resend the current front app on
        // that edge so the StickS3 gets an initial sync.
        state.$linkParams
            .map(\.mtu)
            .removeDuplicates()
            .filter { $0 > 0 }
            .sink { _ in FrontAppMonitor.shared.resend() }
            .store(in: &cancellables)
    }

    // MARK: status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        state.$link
            .removeDuplicates()
            .sink { [weak self] link in self?.updateStatusIcon(link) }
            .store(in: &cancellables)
    }

    // Connected: filled glyph at full strength. Anything else: outline
    // glyph, dimmed the way macOS draws inactive status items.
    private func updateStatusIcon(_ link: AppState.LinkStatus) {
        guard let button = statusItem.button else { return }
        let deviceName: String?
        if case .connected(let name) = link { deviceName = name } else { deviceName = nil }
        let tip = deviceName.map { "Vibe Buddy · 已连接 \($0)" } ?? "Vibe Buddy · 设备未连接"
        button.image = NSImage(
            systemSymbolName: deviceName == nil ? "waveform.circle" : "waveform.circle.fill",
            accessibilityDescription: tip
        )
        button.appearsDisabled = deviceName == nil
        button.toolTip = tip
    }

    // Left click opens the main window; right click (or ctrl-click)
    // shows the menu, which is the only way to quit an agent app.
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            makeStatusMenu().popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.height + 4),
                in: sender
            )
        } else {
            showMainWindow(nil)
        }
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "打开主界面", action: #selector(showMainWindow(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "设置…", action: #selector(showSettings(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Vibe Buddy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        return menu
    }

    // MARK: windows

    @objc func showMainWindow(_ sender: Any?) {
        let window = mainWindow ?? makeWindow(
            title: "Vibe Buddy",
            root: ContentView()
                .environmentObject(state)
                .environmentObject(ble)
                .environmentObject(coord)
        )
        mainWindow = window
        present(window)
    }

    // Reached from ContentView via the responder chain (NSApp delegate is
    // its last stop) and from the Cmd+, / status menu items.
    @objc func showSettings(_ sender: Any?) {
        let window = settingsWindow ?? makeWindow(
            title: "Vibe Buddy 设置",
            root: SettingsView()
                .environmentObject(state)
                .environmentObject(ble)
        )
        settingsWindow = window
        present(window)
    }

    private func makeWindow<V: View>(title: String, root: V) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = title
        // Reused across open/close; closing only hides it.
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func present(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    // An agent app shows no menu bar, but key equivalents still route
    // through NSApp.mainMenu while one of our windows is key — this is
    // what makes Cmd+V work in the credential fields and Cmd+W / Cmd+Q
    // behave normally.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "设置…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "退出 Vibe Buddy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        for submenu in [app, edit, window] {
            let item = NSMenuItem()
            item.submenu = submenu
            main.addItem(item)
        }
        return main
    }
}

// Minimal JSON string escape — covers the only characters that can show
// up in a macOS app name and would corrupt the wire format. We're not
// pulling in JSONEncoder for a single string field.
private func jsonEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s {
        switch ch {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:   out.append(ch)
        }
    }
    return out
}
