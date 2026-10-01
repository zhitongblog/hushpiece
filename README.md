# CallTrans — 本地双向通话同传（英 ⇄ 中）

和外语同事开会时用：

- **对方说英语** → 屏幕底部浮窗实时显示中文字幕（附英文原文）
- **你说中文** → 自动翻译成英语，用英式语音通过虚拟麦克风送进通话，对方直接听到英语
- 浮窗里也可以打字（中文或英文），回车后用英语念给对方听
- 每次通话自动保存中英对照记录

语音识别、翻译、语音合成全部用 macOS 26 自带的端侧模型：不需要 API key、不联网、不收费。

## 原理

```
对方声音（系统音频, ScreenCaptureKit） → 英文识别(en-GB) → 英→中翻译 → 字幕浮窗
你的麦克风 → 中文识别(zh-CN) → 停顿断句 → 中→英翻译 → 英语语音 → BlackHole（通话软件的麦克风）
                       └──────── 你的原声也同时送进 BlackHole（播报英语时自动压低）
```

## 安装

```sh
brew install --cask blackhole-2ch   # 虚拟麦克风，需要管理员密码，装完不用重启
~/code/calltrans/scripts/install.sh # 编译并链接 calltrans 到 /opt/homebrew/bin
calltrans setup                     # 下载模型、申请权限
calltrans doctor                    # 全部 ✅ 即可
```

权限跟着"启动它的终端"走（例如 终端.app 需要有 麦克风 和 屏幕与系统录音 权限）。

## 打电话时

1. **戴耳机**（避免对方声音被麦克风收进去）。
2. 在微信 / Teams / Zoom 的通话设置里，把 **麦克风** 选成 **BlackHole 2ch**，扬声器保持耳机。
3. `calltrans start`（只翻译微信的声音：`calltrans start --app WeChat`）
4. 通话结束：点浮窗的"结束"，或 `calltrans stop`。

浮窗：

- 大字是对方的话的中文，小灰字是英文原文；`…` 结尾的是还没说完的实时预览
- 右侧青色是你的话的英文（对方听到的内容）
- "翻译我的话"开关：关掉后只送你的原声，比如你想直接说英语时
- A− / A+ 调字号，可拖动、可改大小

## CLI

| 命令 | 作用 |
|---|---|
| `calltrans start [选项]` / `run` / `stop` / `status` | 后台启动 / 前台运行 / 结束 / 状态 |
| `calltrans say "文本"` | 让运行中的同传用英语说这句话（中文先翻译；`--raw` 不翻译） |
| `calltrans setup` / `doctor` / `devices` | 初始化 / 自检 / 列设备 |
| `calltrans translate "文本" [--to en\|zh]` | 文本翻译 |
| `calltrans transcribe 文件 [--lang en-GB\|zh-CN] [--translate]` | 音频文件识别（+翻译） |
| `calltrans tts "text" [--output default\|设备] [--save x.caf]` | 试听 / 测试英语语音 |
| `calltrans sessions` / `transcript [ID] [--last N]` / `export [ID]` | 通话记录（export 输出 Markdown） |

同传选项：`--app WeChat`、`--mic 名称`、`--output 名称`、`--voice Daniel`、`--rate 1.0`、`--remote-lang en-GB`、`--my-lang zh-CN`、`--no-passthrough`（只送英语、不送原声）、`--no-gate`（戴耳机时可关掉回声保护）、`--subtitles-only`、`--no-overlay`、`--font-size 20`。测试用：`--remote-file`、`--mic-file`、`--mic-file-delay`。

数据目录：`~/Library/Application Support/CallTrans/`（`sessions/*.jsonl|.md`、`calltrans.log`、`status.json`）。

## MCP

```sh
claude mcp add calltrans -- calltrans mcp                 # 只读
claude mcp add calltrans -- calltrans mcp --allow-write   # 允许 say_in_call
```

工具：`status`、`doctor`、`list_sessions`、`get_transcript`、`translate_text`，以及需要 `--allow-write` 的 `say_in_call`。

## 自测

```sh
scripts/selftest.sh
```

自测全程不需要人工操作：用 `say` 生成英文和中文语音，在扬声器上播放英文，测系统声音采集到中文字幕这条链路；把中文文件当作麦克风输入，测中文到英文这条链路；同时测 `say` 和 MCP。还会把 BlackHole 的输出录回来再识别一遍，确认对方真的听到了英语。

## 已知限制

- 端侧翻译适合日常商务对话，专有名词、口语俚语偶尔会翻得生硬
- 你的一句话说完、停顿约 0.9 秒后才会播报英语（句末有句号时 0.4 秒）
- 不戴耳机时，回声保护会在对方说话期间暂停识别你的话；双方抢话时以对方为准
