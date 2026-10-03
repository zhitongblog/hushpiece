import AVFoundation
import CoreGraphics
import Speech
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
            out.append(Check(name: L("语音识别模型 ", "Speech model ") + l, ok: installed.contains(l), fix: "hushpiece setup"))
        }
        let a = translationLang(remote), b = translationLang(mine)
        out.append(Check(name: L("翻译模型 ", "Translation model ") + "\(a)→\(b)", ok: await Translator.isInstalled(from: a, to: b), fix: L("hushpiece setup（在引导第 2 步点“下载”）", "hushpiece setup (step 2 of the guide → Download)")))
        out.append(Check(name: L("翻译模型 ", "Translation model ") + "\(b)→\(a)", ok: await Translator.isInstalled(from: b, to: a), fix: L("hushpiece setup（在引导第 2 步点“下载”）", "hushpiece setup (step 2 of the guide → Download)")))
        out.append(Check(name: L("麦克风权限", "Microphone permission"), ok: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                         fix: L("hushpiece setup，或 系统设置 → 隐私与安全性 → 麦克风", "hushpiece setup, or System Settings → Privacy & Security → Microphone")))
        out.append(Check(name: L("屏幕与系统录音权限", "Screen & System Audio Recording permission"), ok: CGPreflightScreenCaptureAccess(),
                         fix: L("hushpiece setup，或 系统设置 → 隐私与安全性 → 屏幕与系统录音", "hushpiece setup, or System Settings → Privacy & Security → Screen & System Audio Recording")))
        out.append(Check(name: L("虚拟麦克风", "Virtual microphone"), ok: Devices.blackHole() != nil,
                         fix: Doctor.virtualMicFix))
        return out
    }

#if APPSTORE
    static var virtualMicFix: String { L("可选：有虚拟音频设备时自动使用，没有则只显示字幕", "optional: used automatically when present; otherwise subtitles only") }
#else
    static var virtualMicFix: String { L("brew install --cask blackhole-2ch（需要输入管理员密码）", "brew install --cask blackhole-2ch (asks for an admin password)") }
#endif

    static func print_(_ checks: [Check]) {
        for c in checks {
            print("\(c.ok ? "✅" : "❌") \(c.name)" + (c.ok ? "" : "   → \(c.fix)"))
        }
        print(L("\n注意：上面的权限状态是针对当前启动它的程序（终端，或 耳语同传.app）。", "\nNote: the permissions above belong to whatever launched this (Terminal, or Hushpiece.app)."))
    }
}

