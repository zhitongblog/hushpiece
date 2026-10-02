#!/bin/zsh
# End-to-end self-test. Drives the real binary; no human needed.
#   1. file → ASR → translation, both directions
#   2. live engine: real system-audio capture of English played on the speakers → Chinese line
#   3. live engine: Chinese "mic" file → English line (+ spoken into BlackHole, recorded back and re-recognized)
#   4. typed `say` → English line
#   5. MCP: initialize / tools/list / tools/call
set -uo pipefail
# Default to the bare command on $PATH so launching works the way the user runs it.
B=${HUSHPIECE:-hushpiece}
T=$(mktemp -d)
# Keep test sessions out of the user's real meeting records.
export HUSHPIECE_HOME=$T/home
pass=0; fail=0
ok()  { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; fail=$((fail+1)); }
has() { grep -q -- "$2" <<<"$1" && ok "$3" || { bad "$3"; echo "$1" | sed 's/^/     | /'; }; }

say -v Daniel -o $T/en.aiff "Good morning everyone. Could you send me the report by Friday?"
say -v Tingting -o $T/zh.aiff "我们下周三之前把版本发给你们。"

echo "1. 文件识别 + 翻译"
out=$($B transcribe $T/en.aiff --lang en-GB --translate 2>/dev/null); has "$out" "Friday" "英文识别"; has "$out" "周五" "英→中翻译"
out=$($B transcribe $T/zh.aiff --lang zh-CN --translate 2>/dev/null); has "$out" "周三" "中文识别"; has "$out" "Wednesday" "中→英翻译"

$B stop >/dev/null 2>&1
echo "2+3+4. 实时引擎"
# My speech starts well after their sentence ends: with the speakers on (no headphones) the
# echo guard deliberately ignores my mic while they talk, which would clip my first words.
$B start --remote-lang en-GB --my-lang zh-CN --mic-file $T/zh.aiff --mic-file-delay 11 >/dev/null || bad "start"
sleep 1
afplay $T/en.aiff
BH=$($B devices | grep -i blackhole | cut -f1)
if [[ -n "$BH" ]]; then ffmpeg -loglevel error -f avfoundation -i ":$BH" -t 19 -y $T/bh.wav & rec=$!; fi
sleep 11
$B say "好的，没问题。" >/dev/null
sleep 5
[[ -n "${rec:-}" ]] && wait $rec
tr=$($B transcript)
has "$tr" "\[remote\].*Friday" "对方英语（系统声音采集）→ 识别"
has "$tr" "周五" "对方英语 → 中文字幕"
has "$(grep -A1 "^\[me\]" <<<"$tr")" "Wednesday" "我的中文 → 英文"
has "$(grep -A1 "^\[typed\]" <<<"$tr")" "problem" "打字 say → 英文"
if [[ -n "$BH" ]]; then
  heard=$($B transcribe $T/bh.wav --lang en-GB 2>/dev/null)
  has "$heard" "Wednesday\|problem" "对方真正听到的英语（BlackHole 回录再识别）"
else
  bad "BlackHole 未安装，无法验证对方听到的声音"
fi
$B stop >/dev/null

echo "5. MCP"
mcp=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"translate_text","arguments":{"text":"See you tomorrow"}}}' \
  '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_transcript","arguments":{"last":2}}}' \
  '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"say_in_call","arguments":{"text":"hi"}}}' \
  | $B mcp 2>/dev/null)
has "$mcp" '"serverInfo"' "initialize"
has "$mcp" '"get_transcript"' "tools/list"
has "$mcp" '明天' "translate_text"
has "$mcp" 'Wednesday\|problem' "get_transcript"
has "$mcp" 'requires --allow-write' "写操作默认被拒绝"

rm -rf $T
echo "\n通过 $pass，失败 $fail"
[[ $fail -eq 0 ]]
