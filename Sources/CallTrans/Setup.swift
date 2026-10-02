import AppKit
import AVFoundation
import CoreGraphics
import Speech
import SwiftUI
import Translation

struct Check {
    let name: String
    let ok: Bool
    let fix: String
}

enum Doctor {
    static func checks(remote: String = "en-GB", mine: String = "zh-CN") async -> [Check] {
        var out: [Check] = []
        let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        for l in [remote, mine] {
            out.append(Check(name: "语音识别模型 \(l)", ok: installed.contains(l), fix: "calltrans setup"))
        }
        let a = translationLang(remote), b = translationLang(mine)
        out.append(Check(name: "翻译模型 \(a)→\(b)", ok: await Translator.isInstalled(from: a, to: b), fix: "calltrans setup（在弹窗里点“下载”）"))
        out.append(Check(name: "翻译模型 \(b)→\(a)", ok: await Translator.isInstalled(from: b, to: a), fix: "calltrans setup（在弹窗里点“下载”）"))
        out.append(Check(name: "麦克风权限", ok: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                         fix: "calltrans setup，或 系统设置 → 隐私与安全性 → 麦克风"))
        out.append(Check(name: "屏幕与系统录音权限", ok: CGPreflightScreenCaptureAccess(),
                         fix: "calltrans setup，或 系统设置 → 隐私与安全性 → 屏幕与系统录音"))
        out.append(Check(name: "虚拟麦克风 BlackHole", ok: Devices.blackHole() != nil,
                         fix: "brew install --cask blackhole-2ch（需要输入管理员密码）"))
        return out
    }

    static func print_(_ checks: [Check]) {
        for c in checks {
            print("\(c.ok ? "✅" : "❌") \(c.name)" + (c.ok ? "" : "   → \(c.fix)"))
        }
        print("\n注意：上面的权限状态是针对当前启动它的程序（终端，或 CallTrans.app）。")
    }
}

/// Installs everything that can be installed and asks for every permission. Shows a small window
/// because translation-model downloads must be confirmed by the user in a system sheet.
@MainActor func runSetup(remote: String, mine: String) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let model = SetupModel()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "CallTrans 初始化"
    window.center()
    let src = Locale.Language(identifier: translationLang(remote))
    let dst = Locale.Language(identifier: translationLang(mine))
    window.contentView = NSHostingView(rootView: SetupView(m: model, a: src, b: dst))
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)

    Task {
        for l in [remote, mine] {
            model.log("下载/检查语音识别模型 \(l)…")
            do { try await StreamTranscriber.ensureAssets(Locale(identifier: l)); model.log("  ✅ \(l)") }
            catch { model.log("  ❌ \(l): \(error.localizedDescription)") }
        }
        model.log("请求麦克风权限…")
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        model.log(mic ? "  ✅ 麦克风" : "  ❌ 麦克风被拒绝：系统设置 → 隐私与安全性 → 麦克风 里打开")
        model.log("请求屏幕与系统录音权限…")
        if CGPreflightScreenCaptureAccess() {
            model.log("  ✅ 屏幕与系统录音")
        } else {
            _ = CGRequestScreenCaptureAccess()
            // Also touch ScreenCaptureKit so the app appears in the settings list.
            _ = try? await SCShareableContentProbe.probe()
            model.log("  ⚠️ 请在 系统设置 → 隐私与安全性 → 屏幕与系统录音 中打开本程序，然后重新启动它")
        }
        model.log(Devices.blackHole() != nil ? "✅ 已检测到 BlackHole 虚拟麦克风" : "❌ 未安装 BlackHole：brew install --cask blackhole-2ch")
        model.log("准备翻译模型（如果弹出下载确认，请点“下载”）…")
        model.startTranslation = true
    }
    app.run()
    exit(0)
}

import ScreenCaptureKit
enum SCShareableContentProbe {
    static func probe() async throws -> Int {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).displays.count
    }
}

@MainActor final class SetupModel: ObservableObject {
    @Published var lines: [String] = []
    @Published var startTranslation = false
    @Published var done = false
    func log(_ s: String) { lines.append(s); print(s) }
}

struct SetupView: View {
    @ObservedObject var m: SetupModel
    let a: Locale.Language
    let b: Locale.Language
    @State private var c1: TranslationSession.Configuration?
    @State private var c2: TranslationSession.Configuration?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(m.lines.enumerated()), id: \.offset) { Text($0.element).font(.system(size: 12, design: .monospaced)) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button(m.done ? "完成" : "关闭") { NSApp.terminate(nil) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520, height: 300)
        .onChange(of: m.startTranslation) { if m.startTranslation { c1 = .init(source: a, target: b) } }
        .translationTask(c1) { session in
            do { try await session.prepareTranslation(); m.log("  ✅ 翻译模型 \(a.minimalIdentifier)→\(b.minimalIdentifier)") }
            catch { m.log("  ❌ 翻译模型 \(a.minimalIdentifier)→\(b.minimalIdentifier): \(error.localizedDescription)") }
            c2 = .init(source: b, target: a)
        }
        .translationTask(c2) { session in
            do { try await session.prepareTranslation(); m.log("  ✅ 翻译模型 \(b.minimalIdentifier)→\(a.minimalIdentifier)") }
            catch { m.log("  ❌ 翻译模型 \(b.minimalIdentifier)→\(a.minimalIdentifier): \(error.localizedDescription)") }
            m.log("\n初始化结束。运行 calltrans doctor 复查。")
            m.done = true
        }
    }
}
