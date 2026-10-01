import AppKit
import SwiftUI

struct Line: Identifiable {
    let id = UUID()
    let mine: Bool
    let original: String
    let translated: String
}

final class OverlayModel: ObservableObject {
    @Published var lines: [Line] = []
    @Published var remoteLive = ""
    @Published var remoteLivePreview = ""
    @Published var meLive = ""
    @Published var translateMe = true
    @Published var speaking = false
    @Published var remoteActive = false
    @Published var banner = ""
    @Published var sourceLabel = ""
    @Published var outputLabel = ""
    @Published var fontSize: CGFloat = 20
    var onType: ((String) -> Void)?
    var onQuit: (() -> Void)?

    func add(_ l: Line) {
        lines.append(l)
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
    }
}

struct OverlayView: View {
    @ObservedObject var m: OverlayModel
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !m.banner.isEmpty {
                Text(m.banner).font(.system(size: 12)).foregroundStyle(.orange)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(m.lines) { row($0).id($0.id) }
                        live.id("live")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: m.lines.count) { proxy.scrollTo("live", anchor: .bottom) }
                .onChange(of: m.remoteLive) { proxy.scrollTo("live", anchor: .bottom) }
                .onChange(of: m.meLive) { proxy.scrollTo("live", anchor: .bottom) }
            }
            TextField("输入中文或英文，回车 → 用英语念给对方听", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft = ""
                    if !t.isEmpty { m.onType?(t) }
                }
        }
        .padding(12)
        .frame(minWidth: 520, minHeight: 200)
        .background(.black.opacity(0.93), in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle().fill(m.remoteActive ? .green : .gray).frame(width: 8, height: 8)
            Text(m.sourceLabel).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(m.outputLabel).font(.system(size: 11)).foregroundStyle(.secondary)
            if m.speaking { Text("🔊 正在用英语播报").font(.system(size: 11)).foregroundStyle(.cyan) }
            Spacer()
            Toggle("翻译我的话", isOn: $m.translateMe).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
            Button("A−") { m.fontSize = max(12, m.fontSize - 2) }.buttonStyle(.borderless)
            Button("A+") { m.fontSize = min(40, m.fontSize + 2) }.buttonStyle(.borderless)
            Button("结束") { m.onQuit?() }.buttonStyle(.borderless).foregroundStyle(.red)
        }
        .padding(.top, 14)
    }

    @ViewBuilder private func row(_ l: Line) -> some View {
        if l.mine {
            VStack(alignment: .leading, spacing: 1) {
                Text("我 → " + l.translated).font(.system(size: m.fontSize * 0.8)).foregroundStyle(.cyan)
                Text(l.original).font(.system(size: m.fontSize * 0.55)).foregroundStyle(.gray)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .multilineTextAlignment(.trailing)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text(l.translated).font(.system(size: m.fontSize, weight: .medium))
                Text(l.original).font(.system(size: m.fontSize * 0.55)).foregroundStyle(.gray)
            }
            .textSelection(.enabled)
        }
    }

    @ViewBuilder private var live: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !m.remoteLive.isEmpty {
                if !m.remoteLivePreview.isEmpty {
                    Text(m.remoteLivePreview + " …").font(.system(size: m.fontSize)).foregroundStyle(.white.opacity(0.65))
                }
                Text(m.remoteLive).font(.system(size: m.fontSize * 0.55)).foregroundStyle(.gray.opacity(0.8))
            }
            if !m.meLive.isEmpty {
                Text("我：" + m.meLive + " …").font(.system(size: m.fontSize * 0.6)).foregroundStyle(.cyan.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    convenience init(model: OverlayModel) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(900, screen.width - 40), height: 300)
        let rect = NSRect(x: screen.midX - size.width / 2, y: screen.minY + 30, width: size.width, height: size.height)
        self.init(contentRect: rect,
                  styleMask: [.nonactivatingPanel, .titled, .resizable, .closable, .fullSizeContentView],
                  backing: .buffered, defer: false)
        title = "CallTrans"
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        contentView = NSHostingView(rootView: OverlayView(m: model))
        setFrameAutosaveName("CallTransOverlay")
    }
}
