import AppKit
import ServiceManagement
import SwiftUI

/// The long-lived menu bar app. Sessions (Engine instances) start and stop inside it; the
/// subtitle panel and the model outlive them. `hushpiece run` uses the same controller with
/// `quitWhenSessionEnds` so CLI-started sessions still exit when they end.
@MainActor final class AppController: NSObject, NSMenuDelegate, NSWindowDelegate {
    static var shared: AppController!

    let model = OverlayModel()
    private(set) var engine: Engine?
    private var panel: OverlayPanel!
    private var statusItem: NSStatusItem!
    private var quitWhenSessionEnds = false
    private var timers: [Timer] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var iconPhase = 0
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var stopping = false

    func launch(start cfg: RunConfig?, quitWhenSessionEnds: Bool, showOnboarding: Bool) {
        Self.shared = self
        self.quitWhenSessionEnds = quitWhenSessionEnds
        AppInstance.claim()
        panel = OverlayPanel(model: model)
        model.onType = { [weak self] t in self?.engine?.typed(t) }
        model.onStop = { [weak self] in self?.stopSession() }
        model.onHide = { [weak self] in self?.panel.orderOut(nil) }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = MenuBarIcon.image(phase: 0, active: false)
        statusItem.button?.toolTip = L("耳语同传", "Hushpiece")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        timers.append(Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollControl() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.animateIcon() }
        })
        installSignals()

        if let cfg { startSession(cfg) }
        if showOnboarding { showOnboardingWindow() }
    }

    // MARK: sessions

    func startSession(_ cfg: RunConfig) {
        guard engine == nil, !stopping else { return }
        let e = Engine(cfg, model: model)
        engine = e
        model.starting = true
        if cfg.overlay { showPanel() }
        Task {
            await e.start()
            model.starting = false
        }
    }

    func startFromSettings() { startSession(RunConfig(Args([]))) }

    /// Time-boxed: whatever the frameworks do, the transcript is saved and the app is usable
    /// again within 6 s.
    func stopSession(then: (() -> Void)? = nil) {
        guard let e = engine, !stopping else { then?(); return }
        stopping = true
        var finished = false
        let finish = { [weak self] in
            guard let self, !finished else { return }
            finished = true
            e.saveTranscript()
            self.engine = nil
            self.stopping = false
            self.model.active = false
            self.model.speaking = false
            self.model.remoteActive = false
            self.model.listeners = []
            if self.quitWhenSessionEnds { self.quit() }
            then?()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if !finished { Log.info("shutdown watchdog fired") }
            MainActor.assumeIsolated { finish() }
        }
        Task {
            await e.shutdown()
            finish()
        }
    }

    func quit() {
        if engine != nil, !quitWhenSessionEnds {
            stopSession { [weak self] in self?.quit() }
            return
        }
        AppInstance.release()
        exit(0)
    }

    /// Settings → interface language → "Reopen Now": start a fresh copy of the bundle once this
    /// one has gone (the instance lock would otherwise hand the launch back to us).
    func relaunch() {
        let bundle = Bundle.main.bundleURL.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1.5; /usr/bin/open -n \"$0\"", bundle]
        try? p.run()
        quitWhenSessionEnds = true
        if engine == nil { quit() } else { stopSession() }
    }

    func showPanel() {
        panel.orderFrontRegardless()
    }

    // MARK: CLI / MCP control channel

    private func pollControl() {
        for r in Control.drain() {
            switch r.cmd {
            case "start": startSession(RunConfig(Args(r.args)))
            case "stop": stopSession()
            case "show": showPanel()
            case "onboarding": showOnboardingWindow()
            case "settings": showSettingsWindow()
            case "quit": quit()
            default: Log.info("unknown control command \(r.cmd)")
            }
        }
    }

    private func installSignals() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // A signal means "go away now": end the session, then exit either way.
                    self.quitWhenSessionEnds = true
                    if self.engine == nil { self.quit() } else { self.stopSession() }
                }
            }
            src.resume()
            signalSources.append(src)
        }
        let usr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        signal(SIGUSR1, SIG_IGN)
        usr1.setEventHandler { [weak self] in Task { await self?.engine?.simulateCaptureInterruption() } }
        usr1.resume()
        signalSources.append(usr1)
    }

    // MARK: menu bar icon

    private func animateIcon() {
        let moving = engine != nil && (model.remoteActive || model.speaking)
        if moving { iconPhase += 1 }
        let img = MenuBarIcon.image(phase: moving ? iconPhase : 0, active: engine != nil)
        statusItem.button?.image = img
        let warn = engine != nil && (!model.captureConnected || !model.banner.isEmpty)
        statusItem.button?.title = warn ? " !" : ""
    }

    // MARK: menu

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { rebuild(menu) }
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let st = Prefs.shared
        let remote = Lang.of(st.remoteLang), mine = Lang.of(st.myLang)

        let header = NSMenuItem(title: engine != nil ? L("同传中 · ", "Interpreting · ") + "\(model.remoteName) ⇄ \(model.myName)"
                                                     : L("未在同传 · ", "Not interpreting · ") + "\(remote.plain) ⇄ \(mine.plain)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if engine != nil {
            let who = model.listeners.isEmpty ? L("会议软件还没有使用虚拟麦克风", "No meeting app is using the virtual microphone yet")
                                              : L("\(model.listeners.joined(separator: "、")) 正在使用虚拟麦克风", "\(model.listeners.joined(separator: ", ")) is using the virtual microphone")
            let sub = NSMenuItem(title: who, action: nil, keyEquivalent: ""); sub.isEnabled = false
            menu.addItem(sub)
        }
        menu.addItem(.separator())

        if engine == nil {
            menu.addItem(item(L("开始同传", "Start Interpreting"), #selector(menuStart), "s"))
        } else {
            menu.addItem(item(L("结束同传并保存记录", "End and Save Transcript"), #selector(menuStop), "s"))
        }
        menu.addItem(item(L("显示字幕窗", "Show Subtitles"), #selector(menuShow), "l"))
        let tm = item(L("翻译我的话", "Translate Me"), #selector(menuToggleTranslate), "t")
        tm.state = model.translateMe ? .on : .off
        menu.addItem(tm)
        menu.addItem(.separator())

        menu.addItem(langMenu(L("对方说", "They speak"), current: st.remoteLang, tag: 1))
        menu.addItem(langMenu(L("我说", "I speak"), current: st.myLang, tag: 2))
        menu.addItem(appMenu())
        if engine != nil {
            let note = NSMenuItem(title: L("（语言和声音来源的修改在下次开始时生效）", "(Language and source changes apply next time you start)"), action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        menu.addItem(.separator())

        menu.addItem(recordsMenu())
        menu.addItem(item(L("设置…", "Settings…"), #selector(menuSettings), ","))
        menu.addItem(item(L("使用引导…", "Setup Guide…"), #selector(menuOnboarding), ""))
        menu.addItem(.separator())
        menu.addItem(item(L("退出耳语同传", "Quit Hushpiece"), #selector(menuQuit), "q"))
    }

    private func item(_ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    private func langMenu(_ title: String, current: String, tag: Int) -> NSMenuItem {
        let parent = NSMenuItem(title: title + L("：", ": ") + Lang.of(current).name, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for l in Lang.all {
            let i = NSMenuItem(title: l.name, action: #selector(menuPickLang(_:)), keyEquivalent: "")
            i.target = self
            i.tag = tag
            i.representedObject = l.id
            i.state = l.id == current ? .on : .off
            sub.addItem(i)
        }
        parent.submenu = sub
        return parent
    }

    private func appMenu() -> NSMenuItem {
        let current = Prefs.shared.remoteApp
        let parent = NSMenuItem(title: L("只听：", "Listen to: ") + (current ?? L("全部系统声音", "All system audio")), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let all = NSMenuItem(title: L("全部系统声音", "All system audio"), action: #selector(menuPickApp(_:)), keyEquivalent: "")
        all.target = self; all.state = current == nil ? .on : .off
        sub.addItem(all)
        sub.addItem(.separator())
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap(\.localizedName).sorted()
        for name in Set(apps).sorted() {
            let i = NSMenuItem(title: name, action: #selector(menuPickApp(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = name; i.state = current == name ? .on : .off
            sub.addItem(i)
        }
        parent.submenu = sub
        return parent
    }

    private func recordsMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: L("会议记录", "Meeting Transcripts"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmmss"
        let show = DateFormatter(); show.dateFormat = L("M月d日 HH:mm", "MMM d, HH:mm")
        for url in SessionLog.list().suffix(10).reversed() {
            let id = url.deletingPathExtension().lastPathComponent
            let n = SessionLog.read(url).count
            guard n > 0 else { continue }
            let title = (f.date(from: id).map(show.string(from:)) ?? id) + "  ·  " + L("\(n) 句", n == 1 ? "1 line" : "\(n) lines")
            let i = NSMenuItem(title: title, action: #selector(menuOpenRecord(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = url
            sub.addItem(i)
        }
        if sub.items.isEmpty {
            let e = NSMenuItem(title: L("还没有记录", "No transcripts yet"), action: nil, keyEquivalent: ""); e.isEnabled = false
            sub.addItem(e)
        }
        sub.addItem(.separator())
        let open = NSMenuItem(title: L("打开记录文件夹", "Open Transcripts Folder"), action: #selector(menuOpenFolder), keyEquivalent: "")
        open.target = self
        sub.addItem(open)
        parent.submenu = sub
        return parent
    }

    @objc private func menuStart() { startFromSettings() }
    @objc private func menuStop() { stopSession() }
    @objc private func menuShow() { showPanel() }
    @objc private func menuToggleTranslate() { model.translateMe.toggle() }
    @objc private func menuSettings() { showSettingsWindow() }
    @objc private func menuOnboarding() { showOnboardingWindow() }
    @objc private func menuQuit() { quit() }
    @objc private func menuOpenFolder() { NSWorkspace.shared.open(Paths.sessions) }

    @objc private func menuPickLang(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if sender.tag == 1 { Prefs.shared.remoteLang = id } else { Prefs.shared.myLang = id }
        Task { await OnboardingModel.ensureModelsQuietly() }
    }

    @objc private func menuPickApp(_ sender: NSMenuItem) {
        Prefs.shared.remoteApp = sender.representedObject as? String
    }

    @objc private func menuOpenRecord(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let md = url.deletingPathExtension().appendingPathExtension("md")
        if !FileManager.default.fileExists(atPath: md.path) {
            try? SessionLog.markdown(url).write(to: md, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(md)
    }

    // MARK: windows

    func showOnboardingWindow() {
        if onboardingWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = L("欢迎使用耳语同传", "Welcome to Hushpiece")
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: OnboardingView(m: OnboardingModel(), done: { [weak self, weak w] start in
                Prefs.shared.onboarded = true
                w?.close()
                if start { self?.startFromSettings() }
            }))
            w.center()
            w.delegate = self
            onboardingWindow = w
        }
        bringToFront(onboardingWindow!)
    }

    func showSettingsWindow() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = L("耳语同传 设置", "Hushpiece Settings")
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(overlay: model))
            w.center()
            w.delegate = self
            settingsWindow = w
        }
        bringToFront(settingsWindow!)
    }

    /// A menu bar (accessory) app is often refused activation on macOS 14+, so its windows open
    /// behind whatever app is in front — and the floating subtitle panel covers them too. While
    /// one of our real windows is open, behave like a normal app (Dock icon, activatable) and put
    /// the window on the panel's level, above it.
    private func bringToFront(_ w: NSWindow) {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        w.level = .floating
        w.collectionBehavior.insert(.moveToActiveSpace)
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        // Activation can land a beat later than the order-front; repeat once it has.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.activate()
            w.makeKeyAndOrderFront(nil)
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            let closing = notification.object as? NSWindow
            let others = [onboardingWindow, settingsWindow].compactMap { $0 }.filter { $0 !== closing && $0.isVisible }
            if others.isEmpty { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

/// Six bars, white half and "translated" half like the app icon; template image so it follows
/// the menu bar's light/dark look. Bars ripple while someone is talking.
enum MenuBarIcon {
    static func image(phase: Int, active: Bool) -> NSImage {
        let base: [CGFloat] = [6, 11, 8, 8, 11, 6]
        let img = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            var x: CGFloat = 2
            for (i, h0) in base.enumerated() {
                if i == 3 { x += 1.5 }
                var h = h0
                if phase > 0 { h = max(3, h0 * (0.55 + 0.45 * abs(sin(CGFloat(phase + i * 2) * 0.55)))) }
                if !active { h = max(3, h0 * 0.8) }
                let r = NSRect(x: x, y: 9 - h / 2, width: 2, height: h)
                NSBezierPath(roundedRect: r, xRadius: 1, yRadius: 1).fill()
                x += 3
            }
            if !active {
                // idle: a little lower contrast so "on" is obvious at a glance
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

/// `hushpiece app` / launching the bundle / `hushpiece run`: start the menu bar app.
@MainActor func runAppMode(start cfg: RunConfig?, quitWhenSessionEnds: Bool, showOnboarding: Bool) -> Never {
    if let pid = AppInstance.runningPID() {
        // Second launch (e.g. double-clicking the app again): hand over to the running one.
        try? Control.post(ControlRequest(cmd: showOnboarding ? "onboarding" : "show"))
        print(L("耳语同传已在运行 (pid \(pid))", "Hushpiece is already running (pid \(pid))"))
        exit(0)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    // Test hook: render the windows in a given appearance without touching the user's system setting.
    switch ProcessInfo.processInfo.environment["HUSHPIECE_APPEARANCE"] {
    case "dark": app.appearance = NSAppearance(named: .darkAqua)
    case "light": app.appearance = NSAppearance(named: .aqua)
    default: break
    }
    let controller = AppController()
    controller.launch(start: cfg, quitWhenSessionEnds: quitWhenSessionEnds, showOnboarding: showOnboarding)
    app.run()
    exit(0)
}
