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
            out.append(Check(name: "语音识别模型 \(l)", ok: installed.contains(l), fix: "hushpiece setup"))
        }
        let a = translationLang(remote), b = translationLang(mine)
        out.append(Check(name: "翻译模型 \(a)→\(b)", ok: await Translator.isInstalled(from: a, to: b), fix: "hushpiece setup（在引导第 2 步点“下载”）"))
        out.append(Check(name: "翻译模型 \(b)→\(a)", ok: await Translator.isInstalled(from: b, to: a), fix: "hushpiece setup（在引导第 2 步点“下载”）"))
        out.append(Check(name: "麦克风权限", ok: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                         fix: "hushpiece setup，或 系统设置 → 隐私与安全性 → 麦克风"))
        out.append(Check(name: "屏幕与系统录音权限", ok: CGPreflightScreenCaptureAccess(),
                         fix: "hushpiece setup，或 系统设置 → 隐私与安全性 → 屏幕与系统录音"))
        out.append(Check(name: "虚拟麦克风", ok: Devices.blackHole() != nil,
                         fix: Doctor.virtualMicFix))
        return out
    }

#if APPSTORE
    static let virtualMicFix = "可选：有虚拟音频设备时自动使用，没有则只显示字幕"
#else
    static let virtualMicFix = "brew install --cask blackhole-2ch（需要输入管理员密码）"
#endif

    static func print_(_ checks: [Check]) {
        for c in checks {
            print("\(c.ok ? "✅" : "❌") \(c.name)" + (c.ok ? "" : "   → \(c.fix)"))
        }
        print("\n注意：上面的权限状态是针对当前启动它的程序（终端，或 耳语同传.app）。")
    }
}

