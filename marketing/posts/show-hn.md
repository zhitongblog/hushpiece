# Show HN draft

**When to post**: a weekday, 8–10am US Eastern. Stay around for the first two hours to answer comments.

**Title** (HN titles: no hype, under 80 characters):

    Show HN: Hushpiece – free on-device meeting interpreter for macOS

**URL**: https://github.com/zhitongblog/hushpiece
(HN readers prefer the repo for open-source projects; the site is linked in the README.)

**Text** (the first comment, posted by you right after submitting):

---

Hi HN. I built Hushpiece because I regularly sit in meetings held in a language that isn't my first and couldn't find anything I was comfortable with: the meeting-app options were paid tiers (Zoom's translated captions need Business Plus or a $5/user/month add-on, and the host has to have it; Teams Interpreter needs a Copilot or Teams Premium licence), and the standalone apps upload the call to the cloud and bill by the minute. Some of what gets discussed shouldn't go to a third party, so uploading wasn't an option.

macOS 26 ships on-device speech recognition (SpeechAnalyzer), translation and TTS, so Hushpiece wires those together:

- It captures system audio with ScreenCaptureKit, so it works with any meeting app (Zoom, Teams, Meet in a browser, WeCom, Feishu…) with nothing installed on the other side.
- The other side's speech is transcribed and translated into a floating subtitle panel, original underneath.
- Your own speech is translated when you pause. If you have a virtual audio device (e.g. BlackHole) selected as the meeting app's mic, Hushpiece speaks the translation into the call, mixed with your voice and ducked while it speaks. It only speaks while a meeting app is actually reading that device, which it checks through Core Audio's process list.
- 9 languages, any pair: Chinese, English, Japanese, Korean, French, German, Spanish, Italian, Portuguese.
- Nothing leaves the Mac. No account, no telemetry, no time limit. Transcripts are plain text files on disk.
- There's a CLI and an MCP server (read-only by default), so scripts or an AI assistant can read transcripts or start/stop a session.

Things I learned the hard way, in case they're useful:
- SpeechAnalyzer's finish() can hang on a silent stream, so shutdown steps race a timeout (withTaskGroup waits for every child, so it can't be used for this).
- ScreenCaptureKit stops when someone clicks Stop on the menu-bar recording indicator, and returns "no display" while the screen is locked. Hushpiece reconnects in both cases.
- An app can reserve at most 5 speech locales; switching language pairs has to release old ones.
- The Translation framework sometimes reports a model as not installed on its first query after waking.

Limitations: Apple silicon and macOS 26 only. On-device translation is fine for everyday business talk but weaker than cloud LLMs on names and idioms. It translates sentence by sentence (about a second after you pause), not word by word.

It's MIT-licensed. Signed and notarized DMG in the releases, or `brew install --cask zhitongblog/tap/hushpiece`. Feedback very welcome, especially from people who sit in multilingual meetings every day.

---

**Likely questions to prepare for**
- "Why not Whisper + an LLM?" → Apple's models are already on every Mac running macOS 26, no download of multi-GB weights, low latency, low battery; quality trade-off is stated above.
- "Can it do Windows?" → No; it depends on macOS 26 frameworks.
- "Is the virtual-mic part safe for the other side?" → It only adds your translated speech to your own outgoing audio; nothing is injected into anyone else's machine.
