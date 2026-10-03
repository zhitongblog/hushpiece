import AppKit
import SwiftUI

// MARK: - Palette (the panel is always dark, like film subtitles; matches the app icon:
// white = what was said, amber = what Hushpiece produced for the other side)

enum Palette {
    static let panel = Color(red: 0.067, green: 0.071, blue: 0.106)
    static let amber = Color(red: 1.0, green: 0.773, blue: 0.420)
    static let ok = Color(red: 0.29, green: 0.87, blue: 0.50)
    static let warn = Color(red: 0.98, green: 0.57, blue: 0.24)
    static let bad = Color(red: 0.97, green: 0.40, blue: 0.40)
    static let dim = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.35)
}

struct Line: Identifiable {
    let id = UUID()
    let mine: Bool
    let original: String
    let translated: String
}

/// Everything the overlay and the menu bar show. Lives as long as the app; each session resets it.
final class OverlayModel: ObservableObject {
    @Published var lines: [Line] = []
    @Published var remoteLive = ""
    @Published var remoteLivePreview = ""
    @Published var meLive = ""
    @Published var speaking = false
    @Published var remoteActive = false
    @Published var banner = ""

    @Published var active = false              // a session is running
    @Published var starting = false
    @Published var remoteName = "英语"
    @Published var myName = "中文"
    @Published var remoteShort = "英"
    @Published var myShort = "中"
    @Published var source = ""                 // what we listen to: "全部系统声音" / "企业微信"
    @Published var mic = ""
    @Published var outputDevice: String?       // virtual mic we speak into, nil = subtitles only
    @Published var listeners: [String] = []    // meeting apps reading that virtual mic
    @Published var captureConnected = true
    @Published var notHeard = false            // a translation wasn't spoken because nobody listens
    @Published var echoGuard = true

    @Published var translateMe = Prefs.shared.translateMe { didSet { Prefs.shared.translateMe = translateMe } }
    @Published var fontSize = CGFloat(Prefs.shared.fontSize) { didSet { Prefs.shared.fontSize = Double(fontSize) } }
    @Published var compact = Prefs.shared.compact { didSet { Prefs.shared.compact = compact; onCompactChanged?(compact) } }
    @Published var opacity = Prefs.shared.opacity { didSet { Prefs.shared.opacity = opacity } }

    var onType: ((String) -> Void)?
    var onStop: (() -> Void)?
    var onHide: (() -> Void)?
    var onCompactChanged: ((Bool) -> Void)?

    func add(_ l: Line) {
        lines.append(l)
        if lines.count > 300 { lines.removeFirst(lines.count - 300) }
    }

    func resetForSession(remote: Lang, mine: Lang, translateMe: Bool) {
        let apply = {
            self.lines = []; self.remoteLive = ""; self.remoteLivePreview = ""; self.meLive = ""
            self.banner = ""; self.listeners = []; self.outputDevice = nil; self.notHeard = false
            self.captureConnected = true; self.speaking = false; self.remoteActive = false
            self.remoteName = remote.plain; self.myName = mine.plain
            self.remoteShort = remote.short; self.myShort = mine.short
            self.translateMe = translateMe
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.sync(execute: apply) }
    }
}

// MARK: - The subtitle panel

struct OverlayView: View {
    @ObservedObject var m: OverlayModel
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !m.compact { statusRow }
            if m.compact { compactBody } else { transcript; inputBar }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, m.compact ? 12 : 12)
        .frame(minWidth: 520, minHeight: m.compact ? 96 : 220)
        .background(Palette.panel.opacity(m.opacity), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.08)))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            statusPill
            Text("\(m.remoteShort) → \(m.myShort)")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.white.opacity(0.10), in: Capsule())
                .help("对方说\(m.remoteName)，字幕显示\(m.myName)")
            if m.speaking {
                Label("正在用\(m.remoteName)播报", systemImage: "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.amber)
                    .labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 8)
            // A system switch turns grey in this never-key panel and reads as "off"; draw our own.
            Button { m.translateMe.toggle() } label: {
                HStack(spacing: 6) {
                    Text("翻译我的话").font(.system(size: 11))
                    ZStack(alignment: m.translateMe ? .trailing : .leading) {
                        Capsule().fill(m.translateMe ? Palette.amber : Color.white.opacity(0.18)).frame(width: 28, height: 16)
                        Circle().fill(.white).frame(width: 12, height: 12).padding(.horizontal, 2)
                    }
                    .animation(.easeOut(duration: 0.15), value: m.translateMe)
                }
            }
            .buttonStyle(.plain)
            .help("关掉后只送你的原声，比如你想直接说\(m.remoteName)时")
            .accessibilityLabel("翻译我的话")
            .accessibilityValue(m.translateMe ? "开" : "关")
            iconButton("textformat.size.smaller", "字号减小") { m.fontSize = max(13, m.fontSize - 2) }
            iconButton("textformat.size.larger", "字号增大") { m.fontSize = min(40, m.fontSize + 2) }
            iconButton(m.compact ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
                       m.compact ? "展开" : "紧凑模式（只显示一行字幕）") { m.compact.toggle() }
            iconButton("minus", "隐藏字幕窗（同传继续，点菜单栏图标可恢复）") { m.onHide?() }
            if m.active {
                Button { m.onStop?() } label: {
                    Text("结束").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Palette.bad.opacity(0.85), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("结束同传并保存记录")
            }
        }
        .frame(height: 26)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(statusText).font(.system(size: 11)).foregroundStyle(Palette.dim).lineLimit(1)
        }
    }

    private var statusColor: Color {
        if !m.active { return m.starting ? Palette.warn : Palette.faint }
        if !m.captureConnected { return Palette.warn }
        return m.remoteActive ? Palette.ok : Palette.ok.opacity(0.45)
    }

    private var statusText: String {
        if m.starting { return "正在启动…" }
        if !m.active { return "未在同传" }
        if !m.captureConnected { return "对方声音已断开，正在重连…" }
        return m.remoteActive ? "对方正在说话 · \(m.source)" : "正在听 · \(m.source)"
    }

    // MARK: status row: where my translated voice goes, and whether anyone hears it

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 14) {
                if let out = m.outputDevice {
                    if m.listeners.isEmpty {
                        Label("会议软件还没把麦克风设成 \(out)，你的\(m.remoteName)译文不会播出", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Palette.warn)
                    } else {
                        Label("\(m.listeners.joined(separator: "、")) 正在使用 \(out)，对方能听到你的\(m.remoteName)译文", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Palette.ok)
                    }
                } else if m.active {
                    Label("只显示字幕（没有虚拟麦克风，你的译文请自己念）", systemImage: "captions.bubble")
                        .foregroundStyle(Palette.dim)
                }
                if m.active {
                    Label(m.echoGuard ? "外放：对方说话时暂停识别你" : "耳机：一直识别你", systemImage: m.echoGuard ? "speaker.wave.2" : "headphones")
                        .foregroundStyle(Palette.faint)
                }
            }
            if !m.banner.isEmpty {
                Text(m.banner).foregroundStyle(Palette.bad).lineLimit(3)
            }
        }
        .font(.system(size: 11))
        .labelStyle(.titleAndIcon)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    // MARK: transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if m.lines.isEmpty && m.remoteLive.isEmpty && m.meLive.isEmpty {
                        emptyState
                    }
                    ForEach(m.lines) { row($0).id($0.id) }
                    live.id("live")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.never)
            .defaultScrollAnchor(.bottom)
            .onChange(of: m.lines.count) { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("live", anchor: .bottom) } }
            .onChange(of: m.remoteLive) { proxy.scrollTo("live", anchor: .bottom) }
            .onChange(of: m.meLive) { proxy.scrollTo("live", anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform").font(.system(size: 22)).foregroundStyle(Palette.faint)
            Text(m.active ? "等待对方说话…" : "还没有开始同传")
                .font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.dim)
            Text(m.active ? "对方的\(m.remoteName)会以\(m.myName)字幕显示在这里；你说的\(m.myName)会翻成\(m.remoteName)显示在右侧"
                          : "点菜单栏的耳语同传图标 → 开始同传")
                .font(.system(size: 12)).foregroundStyle(Palette.faint).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
    }

    @ViewBuilder private func row(_ l: Line) -> some View {
        if l.mine {
            HStack {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(l.translated).font(.system(size: m.fontSize * 0.82, weight: .medium)).foregroundStyle(Palette.amber)
                    Text(l.original).font(.system(size: max(11, m.fontSize * 0.55))).foregroundStyle(Palette.dim)
                }
                .multilineTextAlignment(.trailing)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Palette.amber.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(l.translated).font(.system(size: m.fontSize, weight: .semibold))
                Text(l.original).font(.system(size: max(11, m.fontSize * 0.55))).foregroundStyle(Palette.dim)
            }
            .textSelection(.enabled)
        }
    }

    @ViewBuilder private var live: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !m.remoteLive.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if !m.remoteLivePreview.isEmpty {
                        Text(m.remoteLivePreview + " …").font(.system(size: m.fontSize, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    }
                    Text(m.remoteLive).font(.system(size: max(11, m.fontSize * 0.55))).foregroundStyle(Palette.faint)
                }
            }
            if !m.meLive.isEmpty {
                Text(m.meLive + " …").font(.system(size: max(12, m.fontSize * 0.62))).foregroundStyle(Palette.amber.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    // MARK: compact: one subtitle line, like a film

    private var compactBody: some View {
        let last = m.lines.last { !$0.mine }
        let main = !m.remoteLivePreview.isEmpty ? m.remoteLivePreview + " …" : (last?.translated ?? (m.active ? "等待对方说话…" : "未在同传"))
        let sub = !m.remoteLive.isEmpty ? m.remoteLive : (last?.original ?? "")
        return VStack(spacing: 3) {
            Text(main).font(.system(size: m.fontSize + 2, weight: .semibold)).lineLimit(2)
                .foregroundStyle(m.remoteLivePreview.isEmpty && last == nil ? Palette.dim : .white)
            if !sub.isEmpty { Text(sub).font(.system(size: max(11, m.fontSize * 0.55))).foregroundStyle(Palette.dim).lineLimit(1) }
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(.top, 8)
    }

    // MARK: input

    private var inputBar: some View {
        HStack(spacing: 8) {
            // Own dark styling: .roundedBorder keeps a white field in light mode while the
            // panel's .white foreground makes the typed text white-on-white.
            TextField("", text: $draft,
                      prompt: Text("输入\(m.myName)或\(m.remoteName)，回车后用\(m.remoteName)念给对方听").foregroundStyle(Palette.faint))
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                    .foregroundStyle(draft.isEmpty ? Palette.faint : Palette.amber)
            }
            .buttonStyle(.plain)
            .disabled(draft.isEmpty || !m.active)
            .help("用\(m.remoteName)念给对方听")
            .accessibilityLabel("用\(m.remoteName)念给对方听")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.14)))
        .padding(.top, 6)
    }

    private func send() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, m.active else { return }
        draft = ""
        m.onType?(t)
    }

    private func iconButton(_ name: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.dim)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Floating, non-activating subtitle panel. No traffic lights: closing it would look like
/// quitting while the session keeps running (that happened in a real meeting), so the only
/// ways out are "hide" (session continues) and "结束" (session ends).
final class OverlayPanel: NSPanel, NSWindowDelegate {
    override var canBecomeKey: Bool { true }
    private var expandedHeight: CGFloat = 320

    convenience init(model: OverlayModel) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(900, screen.width - 40), height: 320)
        let rect = NSRect(x: screen.midX - size.width / 2, y: screen.minY + 30, width: size.width, height: size.height)
        self.init(contentRect: rect,
                  styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
                  backing: .buffered, defer: false)
        title = "耳语同传"
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(b)?.isHidden = true }
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        delegate = self
        contentView = NSHostingView(rootView: OverlayView(m: model))
        if let saved = Prefs.shared.overlayFrame {
            let r = NSRectFromString(saved)
            // Only restore a frame that is still on a connected screen.
            if r.width >= 520, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r) }) { setFrame(r, display: false) }
        }
        // The autosaved frame may be from compact mode; never start the full view squashed.
        if !model.compact && frame.height < 220 {
            var f = frame; f.size.height = 320; setFrame(f, display: false)
        }
        if model.compact { applyCompact(true, animate: false) }
        model.onCompactChanged = { [weak self] c in self?.applyCompact(c, animate: true) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { orderOut(nil); return false }
    func windowDidMove(_ notification: Notification) { Prefs.shared.overlayFrame = NSStringFromRect(frame) }
    func windowDidResize(_ notification: Notification) { Prefs.shared.overlayFrame = NSStringFromRect(frame) }

    private func applyCompact(_ compact: Bool, animate: Bool) {
        var f = frame
        let newH: CGFloat
        if compact { expandedHeight = max(f.height, 220); newH = 108 } else { newH = expandedHeight }
        f.origin.y += f.height - newH
        f.size.height = newH
        setFrame(f, display: true, animate: animate)
    }
}
